package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"runtime/cgo"
	"sync"
	"testing"
	"time"
)

type gatedListener struct {
	net.Listener
	accepted chan struct{}
	release  chan struct{}
}

func (l *gatedListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		close(l.accepted)
		<-l.release
	}
	return c, err
}

func TestStopBetweenAcceptAndRegistration(t *testing.T) {
	l := &gatedListener{Listener: testListener(t), accepted: make(chan struct{}), release: make(chan struct{})}
	s := serveProxy(l, newProxy(nil), nil)
	c, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	awaitSignal(t, l.accepted)
	stopped := make(chan struct{})
	go func() { stopProxy(s); close(stopped) }()
	awaitSignal(t, s.ctx.Done())
	close(l.release)
	awaitSignal(t, stopped)
	c.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("Accept 返回的迟到连接未关闭")
	}
	awaitSignal(t, s.done)
}

func TestLateDialAndOldCleanupDoNotAffectNewInstance(t *testing.T) {
	up := testListener(t)
	accepted := make(chan net.Conn, 1)
	go func() { c, _ := up.Accept(); accepted <- c }()
	entered, release := make(chan struct{}), make(chan struct{})
	p := newProxy(nil)
	p.Tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		c, err := (&net.Dialer{}).DialContext(ctx, network, up.Addr().String())
		close(entered)
		<-release
		return c, err
	}
	s, _ := testProxy(t, p)
	dialDone := make(chan struct{})
	go func() {
		defer close(dialDone)
		c, err := p.Tr.DialContext(context.Background(), "tcp", up.Addr().String())
		if err == nil {
			c.Close()
		}
	}()
	awaitSignal(t, entered)
	peer := <-accepted
	defer peer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.stop(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("应保留未完成任务: %v", err)
	}
	select {
	case <-s.done:
		t.Fatal("拨号尚未返回却宣称结束")
	default:
	}
	newer, addr := testProxy(t, newProxy(nil))
	close(release)
	awaitSignal(t, dialDone)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
	peer.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := peer.Read(make([]byte, 1)); err == nil {
		t.Fatal("迟到上游未关闭")
	}
	resp, err := http.Get("http://" + addr + "/coords")
	if err != nil {
		t.Fatalf("旧实例清理干扰新实例: %v", err)
	}
	resp.Body.Close()
	if newer.ctx.Err() != nil {
		t.Fatal("新实例被取消")
	}
}

func TestRepeatedAndConcurrentHandleStop(t *testing.T) {
	s, _ := testProxy(t, newProxy(nil))
	h := uintptr(cgo.NewHandle(newProxyHandle(s)))
	var calls sync.WaitGroup
	for range 8 {
		calls.Add(1)
		go func() {
			defer calls.Done()
			if result := stopProxyHandle(h); result != 0 && result != 1 {
				t.Errorf("停止结果 %d", result)
			}
		}()
	}
	calls.Wait()
	if _, ok := proxyForHandle(h); ok {
		t.Fatal("收尾完成但 handle 未删除")
	}
	if stopProxyHandle(h) != 1 || stopProxyHandle(0) != 1 {
		t.Fatal("重复停止应返回无效 handle")
	}
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
}

func TestHandleTimeoutKeepsOwnershipUntilCompletion(t *testing.T) {
	s, _ := testProxy(t, newProxy(nil))
	if !s.beginTask() {
		t.Fatal("无法添加受控任务")
	}
	owned := newProxyHandle(s)
	h := uintptr(cgo.NewHandle(owned))
	if result := stopProxyHandle(h); result != 2 {
		t.Fatalf("期望预算耗尽: %d", result)
	}
	if got, ok := proxyForHandle(h); !ok || got != owned {
		t.Fatal("未结束任务的所有权丢失")
	}
	s.tasks.Done()
	awaitSignal(t, s.done)
	// 必须由预算耗尽时安排的后台路径自动删除，不手动触发 release。
	awaitSignal(t, owned.released)
	if _, ok := proxyForHandle(h); ok {
		t.Fatal("收尾后仍保留 handle")
	}
}

func TestUnexpectedServeFailureCleansInstance(t *testing.T) {
	l := testListener(t)
	s := serveProxy(l, newProxy(nil), nil)
	l.Close()
	awaitSignal(t, s.done)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
}

func TestInvalidStartPreservesCurrentState(t *testing.T) {
	stateMu.Lock()
	cert, lat, lon, enabled, accuracy := globalCACert, currentLat, currentLon, currentEnabled, currentAccuracy
	stateMu.Unlock()
	if s, err := startProxy([]byte("invalid"), nil, 3, 4, true, 25, false); err == nil || s != nil {
		t.Fatal("无效 CA 被接受")
	}
	stateMu.Lock()
	defer stateMu.Unlock()
	if globalCACert != cert || currentLat != lat || currentLon != lon || currentEnabled != enabled || currentAccuracy != accuracy {
		t.Fatal("启动失败改变了状态")
	}
}

type gatedCloseConn struct {
	net.Conn
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (c *gatedCloseConn) Close() error {
	c.once.Do(func() { close(c.entered) })
	<-c.release
	return c.Conn.Close()
}

func TestStopClosesRawBeforeWaitingForOuterClose(t *testing.T) {
	up := testListener(t)
	upDone := make(chan struct{})
	go func() {
		defer close(upDone)
		c, err := up.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		io.Copy(io.Discard, c)
	}()
	entered, release := make(chan struct{}), make(chan struct{})
	p := newProxy(nil)
	p.ConnectDialWithReq = func(req *http.Request, network, addr string) (net.Conn, error) {
		c, err := p.Tr.DialContext(req.Context(), network, addr)
		if err != nil {
			return nil, err
		}
		return &gatedCloseConn{Conn: c, entered: entered, release: release}, nil
	}
	s, addr := testProxy(t, p)
	client := connectThrough(t, addr, up.Addr().String())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- s.stop(ctx) }()
	awaitSignal(t, entered)
	awaitSignal(t, upDone) // 外层 Close 仍受阻，底层真实 TCP 已释放。
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("错误预算结果: %v", err)
		}
	case <-time.After(3 * time.Second):
		close(release)
		t.Fatal("外层 Close 越过停止预算")
	}
	if _, err := client.Read(make([]byte, 1)); err == nil {
		t.Fatal("客户端未关闭")
	}
	select {
	case <-s.done:
		t.Fatal("外层任务未退出却宣称收尾完成")
	default:
	}
	close(release)
	if err := stopProxy(s); err != nil {
		t.Fatal(err)
	}
}
