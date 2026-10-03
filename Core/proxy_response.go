package main

import (
	"io"
	"net/http"
	"sync"

	"github.com/elazarl/goproxy"
)

// responseBody 将重放内容与原始流的关闭责任绑定，也防止 goproxy HTTP 路径重复关闭。
type responseBody struct {
	io.Reader
	source  io.Closer
	once    sync.Once
	err     error
	failure *responseFailure
}

func (b *responseBody) Close() error {
	b.once.Do(func() { b.err = b.source.Close() })
	return b.err
}

// 已消费的读取错误必须在前缀之后重新交给消费者，不能被后续 EOF 掩盖。
type failedBodyReader struct{ err error }

func (r failedBodyReader) Read([]byte) (int, error) { return 0, r.err }

// goproxy v1.8.5 的普通 HTTP 转发只记录 io.Copy 错误，随后仍会正常结束响应。
// 此标记让外层 handler 中止该响应，避免把已消费的上游错误变成完整成功。
type responseFailureKey struct{}
type responseFailure struct{ failed bool }

func (b *responseBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	if err != nil && err != io.EOF && b.failure != nil {
		b.failure.failed = true
	}
	return n, err
}

func prepareWlocRoundTrip(proxy *goproxy.ProxyHttpServer, req *http.Request, ctx *goproxy.ProxyCtx) {
	if !isWlocHost(req.Host) || !isWlocPatchRequest(req) {
		return
	}
	ctx.RoundTripper = goproxy.RoundTripperFunc(func(r *http.Request, _ *goproxy.ProxyCtx) (*http.Response, error) {
		resp, err := proxy.Tr.RoundTrip(r)
		if resp != nil && resp.Body != nil {
			failure, _ := r.Context().Value(responseFailureKey{}).(*responseFailure)
			// 必须在 goproxy 保存原始 Body 前包装，其 HTTP 路径会关闭两个 Body。
			resp.Body = &responseBody{Reader: resp.Body, source: resp.Body, failure: failure}
		}
		return resp, err
	})
}
