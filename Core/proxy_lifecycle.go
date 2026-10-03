package main

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/elazarl/goproxy"
)

const proxyStopTimeout = 5 * time.Second

// 每个实例独占监听器、传输池、连接集合与任务收尾信号。连接关闭不等于任务退出。
type proxyServer struct {
	server      *http.Server
	listener    net.Listener
	proxy       *goproxy.ProxyHttpServer
	cert        *tls.Certificate
	ctx         context.Context
	cancel      context.CancelFunc
	mu          sync.Mutex
	stopping    bool
	connections map[*proxyConn]struct{}
	tasks       sync.WaitGroup
	stopOnce    sync.Once
	done        chan struct{}
}

// 装配约束：上游拨号必须经 Tr.DialContext（包括当前依赖的环境 CONNECT 代理）。
// 连接集合仅保存底层 TCP，不接管 TLS 包装层的协议关闭。
func serveProxy(l net.Listener, p *goproxy.ProxyHttpServer, cert *tls.Certificate) *proxyServer {
	ctx, cancel := context.WithCancel(context.Background())
	s := &proxyServer{listener: l, proxy: p, cert: cert, ctx: ctx, cancel: cancel,
		connections: make(map[*proxyConn]struct{}), done: make(chan struct{})}
	dial := p.Tr.DialContext
	if dial == nil {
		dial = (&net.Dialer{}).DialContext
	}
	p.Tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return s.dial(ctx, network, addr, dial)
	}
	p.OnRequest().HandleConnectFunc(func(host string, _ *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
		return &goproxy.ConnectAction{Action: goproxy.ConnectHijack, Hijack: s.tunnel}, host
	})
	s.server = &http.Server{Handler: http.HandlerFunc(s.serveHTTP),
		BaseContext: func(net.Listener) context.Context { return ctx }}
	s.tasks.Add(1)
	go func() {
		defer s.tasks.Done()
		if err := s.server.Serve(&proxyListener{Listener: l, owner: s}); err != nil && err != http.ErrServerClosed {
			s.mu.Lock()
			stopping := s.stopping
			s.mu.Unlock()
			if !stopping {
				logEvent("proxy server error: " + err.Error())
			}
			// Serve 的非正常退出也走相同的实例清理路径。
			s.beginStop()
		}
	}()
	return s
}

func (s *proxyServer) beginTask() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopping {
		return false
	}
	s.tasks.Add(1)
	return true
}

func (s *proxyServer) serveHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.beginTask() {
		return
	}
	defer s.tasks.Done()
	failure := &responseFailure{}
	r = r.WithContext(context.WithValue(r.Context(), responseFailureKey{}, failure))
	writer := &proxyResponseWriter{ResponseWriter: w, owner: s, connect: r.Method == http.MethodConnect}
	defer func() {
		// goproxy 的普通 HTTP upgrade 返回时不关闭客户端，由当前 handler 收尾。
		if writer.httpHijack != nil {
			writer.httpHijack.Close()
		}
	}()
	s.proxy.ServeHTTP(writer, r)
	if failure.failed {
		panic(http.ErrAbortHandler)
	}
}

func (s *proxyServer) dial(ctx context.Context, network, addr string,
	dial func(context.Context, string, string) (net.Conn, error)) (net.Conn, error) {
	if !s.beginTask() {
		return nil, net.ErrClosed
	}
	defer s.tasks.Done()
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(s.ctx, cancel)
	defer stop()
	defer cancel()
	c, err := dial(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	return s.track(c)
}

func (s *proxyServer) track(c net.Conn) (net.Conn, error) {
	owned := &proxyConn{Conn: c, owner: s}
	s.mu.Lock()
	if s.stopping {
		s.mu.Unlock()
		c.Close()
		return nil, net.ErrClosed
	}
	s.connections[owned] = struct{}{}
	s.mu.Unlock()
	return preserveHalfClose(owned, c), nil
}

func (s *proxyServer) beginStop() {
	s.stopOnce.Do(func() {
		s.mu.Lock()
		s.stopping = true
		connections := make([]*proxyConn, 0, len(s.connections))
		for c := range s.connections {
			connections = append(connections, c)
		}
		s.mu.Unlock()
		// 停止立即撤销网络能力；5 秒预算用于收尾，并非额外的宽限期。
		s.listener.Close()
		s.cancel()
		for _, c := range connections {
			c.Close()
		}
		s.server.Close()
		s.proxy.Tr.CloseIdleConnections()
		stateMu.Lock()
		if globalCACert == s.cert {
			globalCACert = nil
		}
		stateMu.Unlock()
		go func() { s.tasks.Wait(); close(s.done) }()
	})
}

func stopProxy(s *proxyServer) error {
	if s == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), proxyStopTimeout)
	defer cancel()
	return s.stop(ctx)
}

func (s *proxyServer) stop(ctx context.Context) error {
	s.beginStop()
	select {
	case <-s.done:
		return nil
	default:
	}
	select {
	case <-s.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

type proxyListener struct {
	net.Listener
	owner *proxyServer
}

func (l *proxyListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return l.owner.track(c)
}

type proxyConn struct {
	net.Conn
	owner *proxyServer
	once  sync.Once
	err   error
}

func (c *proxyConn) Close() error {
	c.once.Do(func() {
		c.err = c.Conn.Close()
		c.owner.mu.Lock()
		delete(c.owner.connections, c)
		c.owner.mu.Unlock()
	})
	return c.err
}

type halfClosable interface {
	net.Conn
	CloseRead() error
	CloseWrite() error
}
type halfCloseConn struct {
	net.Conn
	half halfClosable
}

func (c *halfCloseConn) CloseRead() error  { return c.half.CloseRead() }
func (c *halfCloseConn) CloseWrite() error { return c.half.CloseWrite() }

func preserveHalfClose(c, original net.Conn) net.Conn {
	if half, ok := original.(halfClosable); ok {
		return &halfCloseConn{Conn: c, half: half}
	}
	return c
}
