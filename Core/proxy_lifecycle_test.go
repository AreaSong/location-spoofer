package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/elazarl/goproxy"
)

func testListener(t *testing.T) net.Listener {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}

func testProxy(t *testing.T, p *goproxy.ProxyHttpServer) (*proxyServer, string) {
	t.Helper()
	p.ConnectDial = nil
	p.Tr.Proxy = nil
	l := testListener(t)
	s := serveProxy(l, p, nil)
	t.Cleanup(func() { stopProxy(s) })
	return s, l.Addr().String()
}

func connectThrough(t *testing.T, proxyAddr, target string) net.Conn {
	t.Helper()
	c, err := net.DialTimeout("tcp", proxyAddr, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	r, err := http.ReadResponse(bufio.NewReader(c), &http.Request{Method: http.MethodConnect})
	if err != nil {
		t.Fatal(err)
	}
	if r.StatusCode != http.StatusOK {
		t.Fatalf("CONNECT: %s", r.Status)
	}
	return c
}

func awaitSignal(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("任务未退出")
	}
}

func TestStopProxyClosesEstablishedConnect(t *testing.T) {
	up := testListener(t)
	done := make(chan struct{})
	go func() {
		defer close(done)
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.Copy(c, c)
	}()
	s, addr := testProxy(t, newProxy(nil))
	c := connectThrough(t, addr, up.Addr().String())
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	c.Write([]byte("ping"))
	b := make([]byte, 4)
	if _, err := io.ReadFull(c, b); err == nil {
		t.Fatalf("停止后 CONNECT 仍可收发: %q", b)
	}
	awaitSignal(t, done)
}

func TestConnectPreservesHalfClose(t *testing.T) {
	up := testListener(t)
	done := make(chan struct{})
	go func() {
		defer close(done)
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		data, _ := io.ReadAll(c)
		c.Write(append([]byte("reply:"), data...))
	}()
	_, addr := testProxy(t, newProxy(nil))
	c := connectThrough(t, addr, up.Addr().String()).(*net.TCPConn)
	c.Write([]byte("ping"))
	c.CloseWrite()
	got, err := io.ReadAll(c)
	if err != nil || string(got) != "reply:ping" {
		t.Fatalf("半关闭丢失响应: %q %v", got, err)
	}
	awaitSignal(t, done)
}

func TestStopActiveConnectWaitsForBothCopies(t *testing.T) {
	up := testListener(t)
	upDone := make(chan struct{})
	go func() {
		defer close(upDone)
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.Copy(c, c)
	}()
	s, addr := testProxy(t, newProxy(nil))
	c := connectThrough(t, addr, up.Addr().String())
	first := make(chan struct{})
	clientDone := make(chan struct{})
	go func() {
		defer close(clientDone)
		data := make([]byte, 4)
		for i := 0; ; i++ {
			if _, err := c.Write([]byte("ping")); err != nil {
				return
			}
			if _, err := io.ReadFull(c, data); err != nil {
				return
			}
			if i == 0 {
				close(first)
			}
		}
	}()
	awaitSignal(t, first)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	awaitSignal(t, clientDone)
	awaitSignal(t, upDone)
	awaitSignal(t, s.done) // tunnel handler 在两项 copy 的 Wait 之后才释放任务。
	if c, err := net.DialTimeout("tcp", addr, time.Second); err == nil {
		c.Close()
		t.Fatal("停止后仍能建连")
	}
}

func TestStopAtHijackBoundary(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	p := newProxy(nil)
	p.OnRequest().HandleConnectFunc(func(host string, _ *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
		close(entered)
		<-release
		return nil, host
	})
	s, addr := testProxy(t, p)
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	target := testListener(t).Addr().String()
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	awaitSignal(t, entered)
	s.beginStop()
	select {
	case <-s.done:
		t.Fatal("提前宣称接管任务结束")
	default:
	}
	close(release)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	c.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("接管连接逃过关闭")
	}
}
