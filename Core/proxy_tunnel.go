package main

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"regexp"
	"sync"

	"github.com/elazarl/goproxy"
)

type proxyResponseWriter struct {
	http.ResponseWriter
	owner      *proxyServer
	connect    bool
	httpHijack net.Conn
}

func (w *proxyResponseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *proxyResponseWriter) Flush()                      { w.ResponseWriter.(http.Flusher).Flush() }

func (w *proxyResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	c, rw, err := w.ResponseWriter.(http.Hijacker).Hijack()
	if err != nil {
		return nil, nil, err
	}
	if !w.connect {
		w.httpHijack = c
		return c, rw, nil
	}
	// 当前 handler 仍持有任务，因而即使停止已开始，计数也不可能从零重新增加。
	w.owner.tasks.Add(1)
	lease := &hijackedConn{Conn: c, done: w.owner.tasks.Done}
	return preserveHalfClose(lease, c), rw, nil
}

// 强制关闭的是 listener 登记的底层连接，不会提前消费此收尾信号。
// goproxy v1.8.5 MITM 主循环通过最终 defer client.Close 交还它；错误返回也会关闭。
type hijackedConn struct {
	net.Conn
	done func()
	once sync.Once
}

func (c *hijackedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(c.done)
	return err
}

var connectPort = regexp.MustCompile(`:\d+$`)

func (s *proxyServer) tunnel(req *http.Request, client net.Conn, _ *goproxy.ProxyCtx) {
	defer client.Close()
	host := req.URL.Host
	if !connectPort.MatchString(host) {
		host += ":80"
	}
	var target net.Conn
	var err error
	switch {
	case s.proxy.ConnectDialWithReq != nil:
		target, err = s.proxy.ConnectDialWithReq(req, "tcp", host)
	case s.proxy.ConnectDial != nil:
		target, err = s.proxy.ConnectDial("tcp", host)
	default:
		target, err = s.proxy.Tr.DialContext(req.Context(), "tcp", host)
	}
	if err != nil {
		io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
		return
	}
	// goproxy 的环境 CONNECT 代理也经 Tr.DialContext 登记底层 TCP。
	// 不再登记 TLS 外层，避免强关时发送 close_notify，挤占整个停止预算。
	defer target.Close()
	if _, err := io.WriteString(client, "HTTP/1.0 200 Connection established\r\n\r\n"); err != nil {
		return
	}
	var copies sync.WaitGroup
	copies.Add(2)
	go func() { defer copies.Done(); copyTunnel(target, client) }()
	go func() { defer copies.Done(); copyTunnel(client, target) }()
	copies.Wait()
}

func copyTunnel(dst, src net.Conn) {
	_, err := io.Copy(dst, src)
	dstHalf, dstOK := dst.(halfClosable)
	srcHalf, srcOK := src.(halfClosable)
	if err == nil && dstOK && srcOK {
		dstHalf.CloseWrite()
		srcHalf.CloseRead()
		return
	}
	dst.Close()
	if err != nil {
		src.Close()
	}
}
