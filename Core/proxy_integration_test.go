package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

func testCA(t *testing.T) (*tls.Certificate, *x509.CertPool) {
	t.Helper()
	certPEM, keyPEM, err := generateCA()
	if err != nil {
		t.Fatal(err)
	}
	cert, err := parseCA(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(certPEM)
	return cert, roots
}

func mitmClient(t *testing.T, addr string, roots *x509.CertPool) *tls.Conn {
	t.Helper()
	c := connectThrough(t, addr, "gs-loc.apple.com:443")
	client := tls.Client(c, &tls.Config{RootCAs: roots, ServerName: "gs-loc.apple.com"})
	if err := client.Handshake(); err != nil {
		t.Fatal(err)
	}
	return client
}

func TestStopMITMIdleAndActive(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(fmt.Sprint("active=", active), func(t *testing.T) {
			upDone := make(chan struct{})
			closed := make(chan struct{}, 1)
			up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(upDone)
				w.Write(bytes.Repeat([]byte("x"), 64<<10))
				w.(http.Flusher).Flush()
				if active {
					<-r.Context().Done()
				}
			}))
			up.Config.ConnState = func(_ net.Conn, state http.ConnState) {
				if state == http.StateClosed {
					closed <- struct{}{}
				}
			}
			up.StartTLS()
			t.Cleanup(up.Close)
			cert, roots := testCA(t)
			p := newProxy(cert)
			p.Tr.Proxy = nil
			p.Tr.TLSClientConfig = up.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
			p.Tr.TLSClientConfig.ServerName = "example.com"
			p.Tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, up.Listener.Addr().String())
			}
			s, addr := testProxy(t, p)
			client := mitmClient(t, addr, roots)
			fmt.Fprint(client, "GET /synthetic HTTP/1.1\r\nHost: gs-loc.apple.com\r\n\r\n")
			resp, err := http.ReadResponse(bufio.NewReader(client), nil)
			if err != nil {
				t.Fatal(err)
			}
			if active {
				if _, err := io.ReadFull(resp.Body, make([]byte, 5)); err != nil {
					t.Fatal(err)
				}
			} else {
				if _, err := io.ReadAll(resp.Body); err != nil {
					t.Fatal(err)
				}
				resp.Body.Close()
			}
			if err := stopProxy(s); err != nil {
				t.Fatal(err)
			}
			awaitSignal(t, upDone)
			awaitSignal(t, closed)
			awaitSignal(t, s.done)
			client.SetReadDeadline(time.Now().Add(time.Second))
			if active {
				_, err := io.ReadAll(resp.Body)
				if err == nil {
					t.Fatal("停止后的未完成响应被报告为成功")
				}
				var timeout net.Error
				if errors.As(err, &timeout) && timeout.Timeout() {
					t.Fatal("客户端仅因测试超时结束")
				}
			} else {
				if _, err := client.Read(make([]byte, 1)); err == nil {
					t.Fatal("MITM 客户端未关闭")
				}
			}
		})
	}
}

func TestHTTPAndHTTPSPassthrough(t *testing.T) {
	for _, secure := range []bool{false, true} {
		t.Run(fmt.Sprint("https=", secure), func(t *testing.T) {
			up := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				io.Copy(w, r.Body)
			}))
			if secure {
				up.StartTLS()
			} else {
				up.Start()
			}
			t.Cleanup(up.Close)
			_, addr := testProxy(t, newProxy(nil))
			proxyURL, _ := url.Parse("http://" + addr)
			tr := up.Client().Transport.(*http.Transport).Clone()
			tr.Proxy = http.ProxyURL(proxyURL)
			defer tr.CloseIdleConnections()
			client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
			resp, err := client.Post(up.URL+"/echo", "text/plain", bytes.NewBufferString("synthetic-body"))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			got, err := io.ReadAll(resp.Body)
			if err != nil || string(got) != "synthetic-body" {
				t.Fatalf("透传失败: %q %v", got, err)
			}
		})
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type signaledBody struct {
	io.Reader
	closed chan struct{}
	observedBody
}

func (b *signaledBody) Read(p []byte) (int, error) { return b.Reader.Read(p) }
func (b *signaledBody) Close() error {
	if b.closes.Add(1) == 1 {
		close(b.closed)
	}
	return nil
}

type endlessReader struct{}

func (endlessReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'x'
	}
	return len(p), nil
}

func TestMITMResponseForwardingClosesOriginal(t *testing.T) {
	for _, early := range []bool{false, true} {
		t.Run(fmt.Sprint("early=", early), func(t *testing.T) {
			cert, roots := testCA(t)
			p := newProxy(cert)
			payload := bytes.Repeat([]byte("abcd"), (1<<18)+19)
			var reader io.Reader = bytes.NewReader(payload)
			if early {
				reader = endlessReader{}
			}
			body := &signaledBody{Reader: reader, closed: make(chan struct{})}
			p.Tr.RegisterProtocol("https", roundTripFunc(func(req *http.Request) (*http.Response, error) {
				resp := wlocResponse(body, -1)
				resp.Request = req
				return resp, nil
			}))
			s, addr := testProxy(t, p)
			client := mitmClient(t, addr, roots)
			fmt.Fprint(client, "POST /clls/wloc HTTP/1.1\r\nHost: gs-loc.apple.com\r\nContent-Length: 0\r\n\r\n")
			resp, err := http.ReadResponse(bufio.NewReader(client), nil)
			if err != nil {
				t.Fatal(err)
			}
			if early {
				_, err = io.ReadFull(resp.Body, make([]byte, 11))
				client.Close()
			} else {
				var got []byte
				got, err = io.ReadAll(resp.Body)
				if !bytes.Equal(got, payload) {
					t.Fatal("真实转发丢失或重复正文")
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			awaitSignal(t, body.closed)
			if err := stopProxy(s); err != nil {
				t.Fatal(err)
			}
			if body.closes.Load() != 1 {
				t.Fatalf("转发后原流关闭次数: %d", body.closes.Load())
			}
		})
	}
}

func TestHTTPWlocForwardingClosesOnce(t *testing.T) {
	for _, payload := range [][]byte{[]byte("small"), bytes.Repeat([]byte("x"), (1<<20)+17)} {
		p := newProxy(nil)
		body := &signaledBody{Reader: bytes.NewReader(payload), closed: make(chan struct{})}
		p.Tr.RegisterProtocol("http", roundTripFunc(func(req *http.Request) (*http.Response, error) {
			resp := wlocResponse(body, -1)
			resp.Request = req
			return resp, nil
		}))
		s, addr := testProxy(t, p)
		proxyURL, _ := url.Parse("http://" + addr)
		tr := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
		defer tr.CloseIdleConnections()
		client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
		resp, err := client.Post("http://gs-loc.apple.com/clls/wloc", "text/plain", nil)
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil || !bytes.Equal(got, payload) {
			t.Fatalf("正文不一致: %v", err)
		}
		awaitSignal(t, body.closed)
		if err := stopProxy(s); err != nil {
			t.Fatal(err)
		}
		if body.closes.Load() != 1 {
			t.Fatalf("HTTP 原流关闭 %d 次", body.closes.Load())
		}
	}
}

func TestHTTPWlocReadFailureIsNotSuccess(t *testing.T) {
	p := newProxy(nil)
	body := &signaledBody{Reader: &partialErrorReader{withBytes: true, failure: io.ErrUnexpectedEOF}, closed: make(chan struct{})}
	p.Tr.RegisterProtocol("http", roundTripFunc(func(req *http.Request) (*http.Response, error) {
		resp := wlocResponse(body, -1)
		resp.Request = req
		return resp, nil
	}))
	s, addr := testProxy(t, p)
	proxyURL, _ := url.Parse("http://" + addr)
	tr := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, Timeout: 3 * time.Second}
	resp, err := client.Post("http://gs-loc.apple.com/clls/wloc", "text/plain", nil)
	if err == nil {
		_, err = io.ReadAll(resp.Body)
		resp.Body.Close()
	}
	if err == nil {
		t.Error("读取失败被真实 HTTP 转发转换成正常成功")
	}
	awaitSignal(t, body.closed)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	if body.closes.Load() != 1 {
		t.Fatal("错误流关闭责任不符")
	}
}

func TestStopMITMBeforeTLSHandshake(t *testing.T) {
	cert, _ := testCA(t)
	s, addr := testProxy(t, newProxy(cert))
	client := connectThrough(t, addr, "gs-loc.apple.com:443")
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	awaitSignal(t, s.done)
	if _, err := client.Read(make([]byte, 1)); err == nil {
		t.Fatal("未开始 TLS 的 MITM 连接逃过清理")
	}
}

func TestOldStopDoesNotClearNewCertificate(t *testing.T) {
	oldCert, newCert := &tls.Certificate{}, &tls.Certificate{}
	old := serveProxy(testListener(t), newProxy(nil), oldCert)
	stateMu.Lock()
	saved := globalCACert
	globalCACert = newCert
	stateMu.Unlock()
	t.Cleanup(func() { stateMu.Lock(); globalCACert = saved; stateMu.Unlock() })
	if err := stopProxy(old); err != nil {
		t.Fatal(err)
	}
	stateMu.Lock()
	unchanged := globalCACert == newCert
	stateMu.Unlock()
	if !unchanged {
		t.Fatal("旧实例清除了新证书")
	}
}

func TestMITMWlocReadFailureClosesOriginal(t *testing.T) {
	cert, roots := testCA(t)
	p := newProxy(cert)
	body := &signaledBody{Reader: &partialErrorReader{withBytes: true, failure: io.ErrUnexpectedEOF}, closed: make(chan struct{})}
	p.Tr.RegisterProtocol("https", roundTripFunc(func(req *http.Request) (*http.Response, error) {
		resp := wlocResponse(body, -1)
		resp.Request = req
		return resp, nil
	}))
	s, addr := testProxy(t, p)
	client := mitmClient(t, addr, roots)
	fmt.Fprint(client, "POST /clls/wloc HTTP/1.1\r\nHost: gs-loc.apple.com\r\nContent-Length: 0\r\n\r\n")
	resp, err := http.ReadResponse(bufio.NewReader(client), nil)
	if err == nil {
		_, err = io.ReadAll(resp.Body)
		resp.Body.Close()
	}
	if err == nil {
		t.Fatal("MITM 丢失上游读取错误")
	}
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		t.Fatal("响应仅因超时失败")
	}
	awaitSignal(t, body.closed)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	if body.closes.Load() != 1 {
		t.Fatal("错误路径关闭次数不符")
	}
}

func TestHTTPUpgradeDoesNotLeakConnectLease(t *testing.T) {
	upDone := make(chan struct{})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		defer close(upDone)
		c, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer c.Close()
		io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
		io.Copy(c, c)
	}))
	t.Cleanup(up.Close)
	s, addr := testProxy(t, newProxy(nil))
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(c, "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", up.URL, up.Listener.Addr())
	r := bufio.NewReader(c)
	resp, err := http.ReadResponse(r, nil)
	if err != nil || resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("升级失败: %v", err)
	}
	c.Write([]byte("ping"))
	got := make([]byte, 4)
	if _, err := io.ReadFull(r, got); err != nil || string(got) != "ping" {
		t.Fatalf("升级透传失败: %q %v", got, err)
	}
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	awaitSignal(t, upDone)
	awaitSignal(t, s.done)
	if _, err := r.ReadByte(); err == nil {
		t.Fatal("升级客户端没有关闭")
	}
}

func TestHTTPSUpstreamProxyClosesUnderlyingTCP(t *testing.T) {
	upDone := make(chan struct{})
	up := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(upDone)
		if r.Method != http.MethodConnect {
			t.Error("缺少 CONNECT")
			return
		}
		c, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer c.Close()
		io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n")
		io.Copy(c, c)
	}))
	t.Cleanup(up.Close)
	p := newProxy(nil)
	p.Tr.TLSClientConfig = up.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
	dial := p.NewConnectDialToProxy(up.URL)
	p.ConnectDialWithReq = func(_ *http.Request, network, addr string) (net.Conn, error) { return dial(network, addr) }
	s, addr := testProxy(t, p)
	client := connectThrough(t, addr, up.Listener.Addr().String())
	client.Write([]byte("ping"))
	got := make([]byte, 4)
	if _, err := io.ReadFull(client, got); err != nil || string(got) != "ping" {
		t.Fatalf("HTTPS 上游代理转发失败: %q %v", got, err)
	}
	s.mu.Lock()
	count := len(s.connections)
	s.mu.Unlock()
	if count != 2 {
		t.Fatalf("应该只登记两端 TCP，没有 TLS 外层: %d", count)
	}
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	awaitSignal(t, upDone)
	awaitSignal(t, s.done)
	if _, err := client.Read(make([]byte, 1)); err == nil {
		t.Fatal("客户端未关闭")
	}
}
