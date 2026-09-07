package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func testLocation(lat, lon int64, accuracy uint64) []byte {
	var out []byte
	out = append(out, writeTag(1, wireVarint)...)
	out = append(out, writeVarint(uint64(lat))...)
	out = append(out, writeTag(2, wireVarint)...)
	out = append(out, writeVarint(uint64(lon))...)
	out = append(out, writeTag(3, wireVarint)...)
	out = append(out, writeVarint(accuracy)...)
	return out
}

func testLocationWithMotion(lat, lon int64, accuracy, motionType, motionConfidence uint64) []byte {
	out := testLocation(lat, lon, accuracy)
	out = append(out, writeTag(11, wireVarint)...)
	out = append(out, writeVarint(motionType)...)
	out = append(out, writeTag(12, wireVarint)...)
	out = append(out, writeVarint(motionConfidence)...)
	return out
}

func testWifiDevice(loc []byte) []byte {
	mac := []byte("aa:bb:cc:dd:ee:ff")
	var out []byte
	out = append(out, writeLengthDelimited(1, mac)...)
	out = append(out, writeLengthDelimited(2, loc)...)
	return out
}

func testFrame(payload []byte) []byte {
	magic := []byte{0, 1, 0, 0, 0, 1, 0, 0}
	var lenBytes [2]byte
	binary.BigEndian.PutUint16(lenBytes[:], uint16(len(payload)))
	var out []byte
	out = append(out, magic...)
	out = append(out, lenBytes[:]...)
	out = append(out, payload...)
	return out
}

func testARPCFrame(payload, suffix []byte) ([]byte, int) {
	var out []byte
	var version [2]byte
	binary.BigEndian.PutUint16(version[:], 1)
	out = append(out, version[:]...)
	for _, value := range [][]byte{[]byte("zh_CN"), []byte("com.apple.locationd"), []byte("20A123")} {
		var length [2]byte
		binary.BigEndian.PutUint16(length[:], uint16(len(value)))
		out = append(out, length[:]...)
		out = append(out, value...)
	}
	var functionID [4]byte
	binary.BigEndian.PutUint32(functionID[:], 1)
	out = append(out, functionID[:]...)
	lengthOffset := len(out)
	var payloadLength [4]byte
	binary.BigEndian.PutUint32(payloadLength[:], uint32(len(payload)))
	out = append(out, payloadLength[:]...)
	out = append(out, payload...)
	out = append(out, suffix...)
	return out, lengthOffset
}

func TestPatchWifiLocation(t *testing.T) {
	payload := writeLengthDelimited(2, testWifiDevice(testLocation(100, 200, 25)))
	body := testFrame(payload)
	c := wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50}

	patched, stats, err := patchWlocBody(body, c)
	if err != nil {
		t.Fatal(err)
	}
	if stats.WiFi != 1 || stats.Locations != 1 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
	if bytes.Equal(patched, body) {
		t.Fatal("body was not patched")
	}

	newLen := int(binary.BigEndian.Uint16(patched[8:10]))
	newPayload := patched[10 : 10+newLen]
	latBytes := append(writeTag(1, wireVarint), writeVarint(uint64(int64(math.Round(c.Latitude*1e8))))...)
	if !bytes.Contains(newPayload, latBytes) {
		t.Fatal("new latitude bytes not found")
	}
}

func TestPatchCellLocation(t *testing.T) {
	for _, field := range []int{22, 24} {
		t.Run(fmt.Sprintf("field_%d", field), func(t *testing.T) {
			cell := writeLengthDelimited(5, testLocation(300, 400, 25))
			payload := writeLengthDelimited(field, cell)
			body := testFrame(payload)
			c := wlocCoords{Latitude: 22.544577, Longitude: 113.94114, Accuracy: 25}

			patched, stats, err := patchWlocBody(body, c)
			if err != nil {
				t.Fatal(err)
			}
			if stats.Cell != 1 || stats.Locations != 1 {
				t.Fatalf("unexpected stats: %+v", stats)
			}
			if bytes.Equal(patched, body) {
				t.Fatal("body was not patched")
			}
		})
	}
}

func TestMotionSimulationDisabledPreservesFields(t *testing.T) {
	original := testLocationWithMotion(100, 200, 25, 7, 88)
	patched, changed, err := patchLocation(original, wlocCoords{
		Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("coordinates were not patched")
	}
	fields, err := parseFields(patched)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range fields {
		if (field.num == 11 || field.num == 12) && !bytes.Contains(original, field.raw) {
			t.Fatalf("motion field %d changed while disabled", field.num)
		}
	}
}

func TestMotionSimulationEnabledReplacesFields(t *testing.T) {
	original := testLocationWithMotion(100, 200, 25, 7, 88)
	patched, _, err := patchLocation(original, wlocCoords{
		Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50,
		MotionSimulationEnabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(patched, append(writeTag(11, wireVarint), writeVarint(motionActivityType)...)) {
		t.Fatal("motion activity type was not replaced")
	}
	if !bytes.Contains(patched, append(writeTag(12, wireVarint), writeVarint(motionActivityConfidence)...)) {
		t.Fatal("motion activity confidence was not replaced")
	}
}

func TestMotionSimulationEnabledAddsMissingFields(t *testing.T) {
	patched, _, err := patchLocation(testLocation(100, 200, 25), wlocCoords{
		Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50,
		MotionSimulationEnabled: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	fields, err := parseFields(patched)
	if err != nil {
		t.Fatal(err)
	}
	counts := map[int]int{}
	for _, field := range fields {
		counts[field.num]++
	}
	if counts[11] != 1 || counts[12] != 1 {
		t.Fatalf("expected one inserted motion field each, got %+v", counts)
	}
}

func TestPatchARPCFramePreservesEnvelopeAndSuffix(t *testing.T) {
	payload := writeLengthDelimited(2, testWifiDevice(testLocation(100, 200, 25)))
	suffix := []byte{0xde, 0xad, 0xbe, 0xef}
	body, lengthOffset := testARPCFrame(payload, suffix)
	originalPrefix := cloneBytes(body[:lengthOffset])
	c := wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50}

	patched, stats, err := patchWlocBody(body, c)
	if err != nil {
		t.Fatal(err)
	}
	if stats.WiFi != 1 || stats.Locations != 1 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
	if !bytes.Equal(patched[:lengthOffset], originalPrefix) {
		t.Fatal("ARPC metadata changed")
	}
	newLength := int(binary.BigEndian.Uint32(patched[lengthOffset : lengthOffset+4]))
	if newLength == len(payload) {
		t.Fatal("ARPC payload length was not updated")
	}
	if !bytes.Equal(patched[lengthOffset+4+newLength:], suffix) {
		t.Fatal("ARPC suffix changed")
	}
}

func TestPatchARPCPayloadLargerThanUint16(t *testing.T) {
	padding := writeLengthDelimited(99, bytes.Repeat([]byte{0x7f}, 70_000))
	location := writeLengthDelimited(2, testWifiDevice(testLocation(100, 200, 25)))
	payload := append(padding, location...)
	body, lengthOffset := testARPCFrame(payload, nil)
	c := wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50}

	patched, stats, err := patchWlocBody(body, c)
	if err != nil {
		t.Fatal(err)
	}
	if stats.WiFi != 1 || stats.Locations != 1 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
	newLength := int(binary.BigEndian.Uint32(patched[lengthOffset : lengthOffset+4]))
	if newLength <= 65535 {
		t.Fatalf("expected 32-bit ARPC payload length, got %d", newLength)
	}
	if !bytes.Contains(patched[lengthOffset+4:lengthOffset+4+newLength], padding) {
		t.Fatal("unknown ARPC payload field changed")
	}
}

func TestPatchMarkerFramePreservesPrefixAndSuffix(t *testing.T) {
	payload := writeLengthDelimited(2, testWifiDevice(testLocation(100, 200, 25)))
	prefix := []byte{0xaa, 0xbb, 0xcc}
	suffix := []byte{0xdd, 0xee}
	var length [2]byte
	binary.BigEndian.PutUint16(length[:], uint16(len(payload)))
	body := append(cloneBytes(prefix), wlocMarker...)
	body = append(body, length[:]...)
	body = append(body, payload...)
	body = append(body, suffix...)
	c := wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50}

	patched, stats, err := patchWlocBody(body, c)
	if err != nil {
		t.Fatal(err)
	}
	if stats.WiFi != 1 || stats.Locations != 1 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
	lengthOffset := len(prefix) + len(wlocMarker)
	newLength := int(binary.BigEndian.Uint16(patched[lengthOffset : lengthOffset+2]))
	if newLength == len(payload) {
		t.Fatal("marker payload length was not updated")
	}
	if !bytes.Equal(patched[:len(prefix)], prefix) {
		t.Fatal("marker prefix changed")
	}
	if !bytes.Equal(patched[lengthOffset+2+newLength:], suffix) {
		t.Fatal("marker suffix changed")
	}
}

func TestPatchBareWlocPayload(t *testing.T) {
	body := writeLengthDelimited(2, testWifiDevice(testLocation(100, 200, 25)))
	c := wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50}

	patched, stats, err := patchWlocBody(body, c)
	if err != nil {
		t.Fatal(err)
	}
	if stats.WiFi != 1 || stats.Locations != 1 {
		t.Fatalf("unexpected stats: %+v", stats)
	}
	if len(patched) > 0 && bytes.HasPrefix(patched, []byte{0, 1, 0, 0}) {
		t.Fatal("bare payload was unexpectedly wrapped")
	}
}

func TestPatchGzip(t *testing.T) {
	payload := writeLengthDelimited(2, testWifiDevice(testLocation(100, 200, 25)))
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(testFrame(payload)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	c := wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 50}

	patched, _, err := patchResponseBody(buf.Bytes(), c)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(patched, testFrame(payload)) {
		t.Fatal("gzip body was not patched")
	}
}

func TestTransparentBodyUnchanged(t *testing.T) {
	body := []byte{1, 2, 3, 4}
	_, _, err := patchResponseBody(body, wlocCoords{Latitude: 31.230416, Longitude: 121.473701, Accuracy: 25})
	if err == nil {
		t.Fatal("expected non-patchable body to error")
	}
}

func TestIsWlocPatchRequestAcceptsClLsWlocPost(t *testing.T) {
	cases := []struct {
		method string
		url    string
		want   bool
	}{
		{http.MethodPost, "https://gs-loc.apple.com/clls/wloc", true},
		{http.MethodPost, "https://gsp-ssl.ls.apple.com/clls/wloc/", true},
		{http.MethodPost, "https://gs-loc-cn.apple.com/foo/clls/wloc", true},
		{http.MethodGet, "https://gs-loc.apple.com/clls/wloc", false},
		{http.MethodPost, "https://gs-loc.apple.com/wloc-settings/save", false},
		{http.MethodPost, "https://gs-loc.apple.com/clls/wloc-extra", false},
	}
	for _, tc := range cases {
		req := httptest.NewRequest(tc.method, tc.url, nil)
		if got := isWlocPatchRequest(req); got != tc.want {
			t.Fatalf("%s %s: got %v want %v", tc.method, tc.url, got, tc.want)
		}
	}
}

func TestPatchWlocResponsePassesThroughOversizedBody(t *testing.T) {
	payload := bytes.Repeat([]byte("x"), (1<<20)+1)
	req := httptest.NewRequest(http.MethodPost, "https://gs-loc.apple.com/clls/wloc", nil)
	resp := &http.Response{
		StatusCode:    http.StatusOK,
		Request:       req,
		Header:        make(http.Header),
		Body:          io.NopCloser(bytes.NewReader(payload)),
		ContentLength: int64(len(payload)),
	}

	patched := patchWlocResponse(resp, nil)
	got, err := io.ReadAll(patched.Body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("oversized WLOC response was changed or truncated")
	}
}

func TestServeLocalRequestsKeepsUnrelatedRequestBodyStreaming(t *testing.T) {
	const secret = "body-must-not-be-buffered-or-logged"
	req := httptest.NewRequest(http.MethodPost, "https://example.com/upload", bytes.NewBufferString(secret))
	returned, response := serveLocalRequests(req, nil)
	if response != nil {
		t.Fatalf("unexpected local response: %d", response.StatusCode)
	}
	got, err := io.ReadAll(returned.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != secret {
		t.Fatalf("request body changed: got %q", got)
	}
	if logs := drainLogs(); bytes.Contains([]byte(logs), []byte(secret)) {
		t.Fatal("request body leaked into diagnostic logs")
	}
}

func TestCoordsEndpointReturnsAtomicSnapshot(t *testing.T) {
	stateMu.Lock()
	previousLat, previousLon := currentLat, currentLon
	previousEnabled, previousAccuracy := currentEnabled, currentAccuracy
	currentLat, currentLon, currentEnabled, currentAccuracy = 0, 0, false, 0
	stateMu.Unlock()
	t.Cleanup(func() {
		stateMu.Lock()
		currentLat, currentLon = previousLat, previousLon
		currentEnabled, currentAccuracy = previousEnabled, previousAccuracy
		stateMu.Unlock()
	})

	handler := newProxy(nil).NonproxyHandler
	const updates = 20_000
	const readers = 8
	const readsPerReader = 2_500

	var writers sync.WaitGroup
	writers.Add(1)
	go func() {
		defer writers.Done()
		for i := 1; i <= updates; i++ {
			stateMu.Lock()
			currentLat = float64(i)
			currentLon = -float64(i)
			currentEnabled = i%2 == 0
			currentAccuracy = i
			stateMu.Unlock()
		}
	}()

	errs := make(chan error, readers)
	var readersGroup sync.WaitGroup
	for range readers {
		readersGroup.Add(1)
		go func() {
			defer readersGroup.Done()
			for i := 0; i < readsPerReader; i++ {
				recorder := httptest.NewRecorder()
				handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "http://proxy.local/coords", nil))
				var snapshot struct {
					Enabled  bool    `json:"enabled"`
					Lat      float64 `json:"lat"`
					Lon      float64 `json:"lon"`
					Accuracy int     `json:"accuracy"`
				}
				if err := json.Unmarshal(recorder.Body.Bytes(), &snapshot); err != nil {
					errs <- err
					return
				}
				if snapshot.Lat != 0 && (snapshot.Lon != -snapshot.Lat || snapshot.Accuracy != int(snapshot.Lat)) {
					errs <- fmt.Errorf("torn coordinate snapshot: %+v", snapshot)
					return
				}
			}
		}()
	}
	readersGroup.Wait()
	writers.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}
