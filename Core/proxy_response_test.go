package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync/atomic"
	"testing"
)

type observedBody struct {
	io.Reader
	closes   atomic.Int32
	closeErr error
}

func (b *observedBody) Close() error { b.closes.Add(1); return b.closeErr }

func wlocResponse(body io.ReadCloser, length int64) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Request:    httptest.NewRequest(http.MethodPost, "https://gs-loc.apple.com/clls/wloc", nil),
		Header:     make(http.Header), Body: body, ContentLength: length,
	}
}

func TestPatchUnknownOversizedBodyClosesOriginal(t *testing.T) {
	payload := bytes.Repeat([]byte("abcd"), (1<<18)+10)
	body := &observedBody{Reader: bytes.NewReader(payload)}
	resp := patchWlocResponse(wlocResponse(body, -1), nil)
	got, err := io.ReadAll(resp.Body)
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("透传内容不一致: %v", err)
	}
	resp.Body.Close()
	if body.closes.Load() != 1 {
		t.Fatalf("原始 Body.Close 次数 = %d，期望 1", body.closes.Load())
	}
}

func TestPatchBodyEarlyClose(t *testing.T) {
	closeErr := errors.New("关闭失败")
	body := &observedBody{Reader: bytes.NewReader(bytes.Repeat([]byte("x"), (1<<20)+100)), closeErr: closeErr}
	resp := patchWlocResponse(wlocResponse(body, -1), nil)
	if body.closes.Load() != 0 {
		t.Fatal("透传前提前关闭")
	}
	if _, err := resp.Body.Read(make([]byte, 7)); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := resp.Body.Close(); !errors.Is(err, closeErr) {
			t.Fatalf("关闭错误丢失: %v", err)
		}
	}
	if body.closes.Load() != 1 {
		t.Fatal("提前关闭未准确释放一次")
	}
}

type partialErrorReader struct {
	failed    bool
	failure   error
	withBytes bool
}

func (r *partialErrorReader) Read(p []byte) (int, error) {
	if r.failed {
		return 0, io.EOF
	}
	r.failed = true
	if r.withBytes {
		return copy(p, "prefix"), r.failure
	}
	return 0, r.failure
}

func TestPatchBodyReplaysReadError(t *testing.T) {
	for _, withBytes := range []bool{false, true} {
		t.Run(fmtBool(withBytes), func(t *testing.T) {
			failure := errors.New("读取中断")
			body := &observedBody{Reader: &partialErrorReader{failure: failure, withBytes: withBytes}}
			resp := wlocResponse(body, -1)
			resp.StatusCode = http.StatusPartialContent
			resp.Header.Set("X-Synthetic", "unchanged")
			before := resp.Header.Clone()
			gotResp := patchWlocResponse(resp, nil)
			got, err := io.ReadAll(gotResp.Body)
			want := ""
			if withBytes {
				want = "prefix"
			}
			if string(got) != want || !errors.Is(err, failure) {
				t.Fatalf("内容或错误丢失: %q %v", got, err)
			}
			if gotResp.ContentLength != -1 || gotResp.StatusCode != http.StatusPartialContent || !reflect.DeepEqual(before, gotResp.Header) {
				t.Fatal("改变透传元数据")
			}
			gotResp.Body.Close()
			if body.closes.Load() != 1 {
				t.Fatal("错误流未关闭")
			}
		})
	}
}

func fmtBool(v bool) string {
	if v {
		return "部分字节与错误同时返回"
	}
	return "无字节错误"
}

func TestPatchBodyNormalCloseOwnership(t *testing.T) {
	stateMu.Lock()
	oldEnabled, oldLat, oldLon, oldAccuracy := currentEnabled, currentLat, currentLon, currentAccuracy
	stateMu.Unlock()
	t.Cleanup(func() {
		stateMu.Lock()
		currentEnabled, currentLat, currentLon, currentAccuracy = oldEnabled, oldLat, oldLon, oldAccuracy
		stateMu.Unlock()
	})
	for _, tc := range []struct {
		name             string
		enabled, changes bool
		payload          []byte
		length           int64
	}{
		{"未启用", false, false, makeTestWlocBody(), -1},
		{"成功改写", true, true, makeTestWlocBody(), -1},
		{"无改写内容", true, false, []byte("not-wloc"), -1},
		{"空响应", true, false, nil, 0},
		{"已知长度超限", true, false, bytes.Repeat([]byte("x"), (1<<20)+1), (1 << 20) + 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stateMu.Lock()
			currentEnabled, currentLat, currentLon, currentAccuracy = tc.enabled, 31, 121, 25
			stateMu.Unlock()
			body := &observedBody{Reader: bytes.NewReader(tc.payload)}
			resp := patchWlocResponse(wlocResponse(body, tc.length), nil)
			got, err := io.ReadAll(resp.Body)
			if err != nil || bytes.Equal(got, tc.payload) == tc.changes {
				t.Fatalf("正文变化不符: %v", err)
			}
			resp.Body.Close()
			if body.closes.Load() != 1 {
				t.Fatalf("关闭次数: %d", body.closes.Load())
			}
		})
	}
}

func TestPatchUnknownBodyReadsOnlyBoundedPrefix(t *testing.T) {
	payload := bytes.NewReader(bytes.Repeat([]byte("x"), 2<<20))
	body := &observedBody{Reader: payload}
	resp := patchWlocResponse(wlocResponse(body, -1), nil)
	if remaining := payload.Len(); remaining != (1<<20)-1 {
		t.Fatalf("预读超出上限: remaining=%d", remaining)
	}
	resp.Body.Close()
}
