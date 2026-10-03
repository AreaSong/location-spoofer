package main

/*
#cgo CFLAGS: -DGOOS_ios -DNDEBUG
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"runtime/cgo"
	"strconv"
	"sync"
)

//export wloccore_version
func wloccore_version() *C.char {
	return C.CString("0.1.0")
}

//export wloccore_generateca
func wloccore_generateca() (r0, r1 *C.char) {
	logEvent("generateca started")
	cert, key, err := generateCA()
	if err != nil {
		logEvent("generateca failed: " + err.Error())
		return nil, nil
	}
	logEvent("generateca completed")
	return C.CString(string(cert)), C.CString(string(key))
}

//export wloccore_validateca
func wloccore_validateca(certData, keyData *C.char) C.int {
	if certData == nil || keyData == nil {
		return 0
	}
	if _, err := parseCA([]byte(C.GoString(certData)), []byte(C.GoString(keyData))); err != nil {
		logEvent("validateca failed: " + err.Error())
		return 0
	}
	return 1
}

//export wloccore_startproxyv2
func wloccore_startproxyv2(certData, keyData *C.char, lat, lon C.double, enabled C.int, accuracy C.int, motionEnabled C.int) C.uintptr_t {
	if certData == nil || keyData == nil {
		return 0
	}
	srv, err := startProxy(
		[]byte(C.GoString(certData)),
		[]byte(C.GoString(keyData)),
		float64(lat),
		float64(lon),
		enabled != 0,
		int(accuracy),
		motionEnabled != 0,
	)
	if err != nil {
		logEvent("startproxy failed: " + err.Error())
		return 0
	}
	return C.uintptr_t(cgo.NewHandle(newProxyHandle(srv)))
}

//export wloccore_stopproxy
func wloccore_stopproxy(h C.uintptr_t) C.int {
	return C.int(stopProxyHandle(uintptr(h)))
}

type proxyHandle struct {
	server      *proxyServer
	cleanupOnce sync.Once
	deleteOnce  sync.Once
	released    chan struct{}
}

func newProxyHandle(server *proxyServer) *proxyHandle {
	return &proxyHandle{server: server, released: make(chan struct{})}
}

var proxyHandleMu sync.Mutex

func stopProxyHandle(h uintptr) int {
	logEvent("stopproxy requested")
	owned, ok := proxyForHandle(h)
	if !ok {
		logEvent("stopproxy failed: invalid handle")
		return 1
	}
	if err := stopProxy(owned.server); err != nil {
		// 网络已关闭；Swift 可显示已停止。尚未退出的任务由 Core 保有 handle，
		// 等待实际收尾后删除，不能依赖上层保留 handle 或再次调用 stop。
		owned.cleanupOnce.Do(func() {
			go func() { <-owned.server.done; owned.release(h) }()
		})
		logEvent("stopproxy network closed; cleanup pending: " + err.Error())
		return 2
	}
	owned.release(h)
	logEvent("stopproxy completed")
	return 0
}

func (h *proxyHandle) release(value uintptr) {
	h.deleteOnce.Do(func() {
		proxyHandleMu.Lock()
		defer proxyHandleMu.Unlock()
		cgo.Handle(value).Delete()
		close(h.released)
	})
}

func proxyForHandle(h uintptr) (owned *proxyHandle, ok bool) {
	if h == 0 {
		return nil, false
	}
	proxyHandleMu.Lock()
	defer proxyHandleMu.Unlock()
	defer func() {
		if recover() != nil {
			owned, ok = nil, false
		}
	}()
	owned, ok = cgo.Handle(h).Value().(*proxyHandle)
	return owned, ok
}

//export wloccore_setpatchconfig
func wloccore_setpatchconfig(lat, lon C.double, enabled C.int, accuracy C.int, motionEnabled C.int) {
	stateMu.Lock()
	currentLat = float64(lat)
	currentLon = float64(lon)
	currentEnabled = enabled != 0
	currentAccuracy = int(accuracy)
	currentMotionSimulationEnabled = motionEnabled != 0
	stateMu.Unlock()
	logEvent("setpatchconfig enabled=" + strconv.FormatBool(enabled != 0) +
		" accuracy=" + strconv.Itoa(int(accuracy)) +
		" motion=" + strconv.FormatBool(motionEnabled != 0))
}

//export wloccore_getcoords
func wloccore_getcoords() (lat, lon C.double, enabled C.int) {
	stateMu.Lock()
	defer stateMu.Unlock()
	lat = C.double(currentLat)
	lon = C.double(currentLon)
	enabled = 0
	if currentEnabled {
		enabled = 1
	}
	return lat, lon, enabled
}

//export wloccore_drainlogs
func wloccore_drainlogs() *C.char {
	s := drainLogs()
	if s == "" {
		return nil
	}
	return C.CString(s)
}

//export wloccore_testpatch
func wloccore_testpatch(lat, lon C.double, accuracy C.int) *C.char {
	c := wlocCoords{Latitude: float64(lat), Longitude: float64(lon), Accuracy: int(accuracy)}
	original := makeTestWlocBody()
	patched, stats, err := patchWlocBody(original, c)
	if err != nil {
		return C.CString("error: " + err.Error())
	}
	if stats.Locations == 0 {
		return C.CString("error: no location entries found")
	}
	if len(patched) < 10 {
		return C.CString("error: patched body too short")
	}
	newLen := int(binary.BigEndian.Uint16(patched[8:10]))
	if newLen <= 0 || 10+newLen > len(patched) {
		return C.CString("error: invalid patched length")
	}
	newPayload := patched[10 : 10+newLen]
	wantLat := append(writeTag(1, wireVarint), writeVarint(uint64(int64(math.Round(c.Latitude*1e8))))...)
	wantLon := append(writeTag(2, wireVarint), writeVarint(uint64(int64(math.Round(c.Longitude*1e8))))...)
	if !bytes.Contains(newPayload, wantLat) {
		return C.CString("error: patched latitude mismatch")
	}
	if !bytes.Contains(newPayload, wantLon) {
		return C.CString("error: patched longitude mismatch")
	}
	return C.CString(fmt.Sprintf("ok: lat=%f lon=%f wifi=%d cell=%d locations=%d", c.Latitude, c.Longitude, stats.WiFi, stats.Cell, stats.Locations))
}

//export wloccore_refreshverifytoken
func wloccore_refreshverifytoken() *C.char {
	return C.CString(refreshVerifyToken())
}
