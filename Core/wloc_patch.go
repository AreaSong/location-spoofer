package main

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
)

const (
	wireVarint      = 0
	wireFixed64     = 1
	wireLengthDelim = 2
	wireFixed32     = 5
)

type wlocCoords struct {
	Latitude                float64
	Longitude               float64
	Accuracy                int
	MotionSimulationEnabled bool
}

const (
	motionActivityType       = 63
	motionActivityConfidence = 467
)

type patchStats struct {
	WiFi      int
	Cell      int
	Locations int
	Skipped   int
}

type wireField struct {
	num      int
	wireType int
	value    []byte
	raw      []byte
}

var macPattern = regexp.MustCompile(`^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$`)

var wlocMarker = []byte{0, 0, 0, 1, 0, 0}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func cloneBytes(b []byte) []byte {
	return append([]byte(nil), b...)
}

func readVarint(data []byte) (uint64, int, error) {
	var v uint64
	for i := 0; i < len(data); i++ {
		if i >= 10 {
			return 0, 0, errors.New("varint too long")
		}
		b := data[i]
		v |= uint64(b&0x7f) << (7 * i)
		if b&0x80 == 0 {
			return v, i + 1, nil
		}
	}
	return 0, 0, errors.New("truncated varint")
}

func writeVarint(v uint64) []byte {
	var out []byte
	for v >= 0x80 {
		out = append(out, byte(v)|0x80)
		v >>= 7
	}
	return append(out, byte(v))
}

func writeTag(num, wireType int) []byte {
	return writeVarint(uint64(num<<3 | wireType))
}

func writeLengthDelimited(num int, value []byte) []byte {
	var out []byte
	out = append(out, writeTag(num, wireLengthDelim)...)
	out = append(out, writeVarint(uint64(len(value)))...)
	out = append(out, value...)
	return out
}

func parseFields(data []byte) ([]wireField, error) {
	var fields []wireField
	idx := 0
	for idx < len(data) {
		start := idx
		tag, n, err := readVarint(data[idx:])
		if err != nil {
			return nil, err
		}
		idx += n
		num := int(tag >> 3)
		wire := int(tag & 7)
		if num == 0 {
			return nil, errors.New("invalid protobuf field 0")
		}
		var value []byte
		switch wire {
		case wireVarint:
			_, vn, err := readVarint(data[idx:])
			if err != nil {
				return nil, err
			}
			value = cloneBytes(data[idx : idx+vn])
			idx += vn
		case wireFixed64:
			if idx+8 > len(data) {
				return nil, errors.New("truncated fixed64")
			}
			value = cloneBytes(data[idx : idx+8])
			idx += 8
		case wireLengthDelim:
			l, ln, err := readVarint(data[idx:])
			if err != nil {
				return nil, err
			}
			idx += ln
			if l > uint64(len(data)-idx) {
				return nil, errors.New("truncated length-delimited")
			}
			value = cloneBytes(data[idx : idx+int(l)])
			idx += int(l)
		case wireFixed32:
			if idx+4 > len(data) {
				return nil, errors.New("truncated fixed32")
			}
			value = cloneBytes(data[idx : idx+4])
			idx += 4
		default:
			return nil, fmt.Errorf("unsupported wire type %d", wire)
		}
		fields = append(fields, wireField{
			num:      num,
			wireType: wire,
			value:    value,
			raw:      cloneBytes(data[start:idx]),
		})
	}
	return fields, nil
}

func patchLocation(loc []byte, c wlocCoords) ([]byte, bool, error) {
	fields, err := parseFields(loc)
	if err != nil {
		return loc, false, err
	}
	hasLat, hasLon := false, false
	for _, f := range fields {
		if f.num == 1 && f.wireType == wireVarint {
			hasLat = true
		}
		if f.num == 2 && f.wireType == wireVarint {
			hasLon = true
		}
	}
	if !hasLat || !hasLon {
		return loc, false, nil
	}

	lat := int64(math.Round(c.Latitude * 1e8))
	lon := int64(math.Round(c.Longitude * 1e8))
	var out []byte
	changed := false
	hasMotionType, hasMotionConfidence := false, false
	for _, f := range fields {
		switch {
		case f.num == 1 && f.wireType == wireVarint:
			raw := append(writeTag(1, wireVarint), writeVarint(uint64(lat))...)
			if !bytes.Equal(raw, f.raw) {
				changed = true
			}
			out = append(out, raw...)
		case f.num == 2 && f.wireType == wireVarint:
			raw := append(writeTag(2, wireVarint), writeVarint(uint64(lon))...)
			if !bytes.Equal(raw, f.raw) {
				changed = true
			}
			out = append(out, raw...)
		case f.num == 3 && f.wireType == wireVarint:
			raw := append(writeTag(3, wireVarint), writeVarint(uint64(c.Accuracy))...)
			if !bytes.Equal(raw, f.raw) {
				changed = true
			}
			out = append(out, raw...)
		case c.MotionSimulationEnabled && f.num == 11 && f.wireType == wireVarint:
			hasMotionType = true
			raw := append(writeTag(11, wireVarint), writeVarint(motionActivityType)...)
			if !bytes.Equal(raw, f.raw) {
				changed = true
			}
			out = append(out, raw...)
		case c.MotionSimulationEnabled && f.num == 12 && f.wireType == wireVarint:
			hasMotionConfidence = true
			raw := append(writeTag(12, wireVarint), writeVarint(motionActivityConfidence)...)
			if !bytes.Equal(raw, f.raw) {
				changed = true
			}
			out = append(out, raw...)
		default:
			out = append(out, f.raw...)
		}
	}
	if c.MotionSimulationEnabled && !hasMotionType {
		out = append(out, writeTag(11, wireVarint)...)
		out = append(out, writeVarint(motionActivityType)...)
		changed = true
	}
	if c.MotionSimulationEnabled && !hasMotionConfidence {
		out = append(out, writeTag(12, wireVarint)...)
		out = append(out, writeVarint(motionActivityConfidence)...)
		changed = true
	}
	return out, changed, nil
}

func patchWifiDevice(device []byte, c wlocCoords, st *patchStats) ([]byte, bool, error) {
	fields, err := parseFields(device)
	if err != nil {
		return device, false, err
	}
	hasMac := false
	for _, f := range fields {
		if f.num == 1 && f.wireType == wireLengthDelim && macPattern.Match(f.value) {
			hasMac = true
		}
	}
	if !hasMac {
		return device, false, nil
	}

	var out []byte
	changed := false
	for _, f := range fields {
		if f.num == 2 && f.wireType == wireLengthDelim {
			newVal, subChanged, err := patchLocation(f.value, c)
			if err != nil {
				st.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
				st.Locations++
			}
			out = append(out, writeLengthDelimited(2, newVal)...)
		} else {
			out = append(out, f.raw...)
		}
	}
	if changed {
		st.WiFi++
	}
	return out, changed, nil
}

func patchCellResponse(cell []byte, c wlocCoords, st *patchStats) ([]byte, bool, error) {
	fields, err := parseFields(cell)
	if err != nil {
		return cell, false, err
	}

	var out []byte
	changed := false
	for _, f := range fields {
		if f.num == 5 && f.wireType == wireLengthDelim {
			newVal, subChanged, err := patchLocation(f.value, c)
			if err != nil {
				st.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
				st.Locations++
			}
			out = append(out, writeLengthDelimited(5, newVal)...)
		} else {
			out = append(out, f.raw...)
		}
	}
	if changed {
		st.Cell++
	}
	return out, changed, nil
}

func patchWlocPayload(payload []byte, c wlocCoords, st *patchStats) ([]byte, bool, error) {
	fields, err := parseFields(payload)
	if err != nil {
		return payload, false, err
	}

	var out []byte
	changed := false
	for _, f := range fields {
		switch {
		case f.num == 2 && f.wireType == wireLengthDelim:
			newVal, subChanged, err := patchWifiDevice(f.value, c, st)
			if err != nil {
				st.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
			}
			out = append(out, writeLengthDelimited(2, newVal)...)
		case (f.num == 22 || f.num == 24) && f.wireType == wireLengthDelim:
			newVal, subChanged, err := patchCellResponse(f.value, c, st)
			if err != nil {
				st.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
			}
			out = append(out, writeLengthDelimited(f.num, newVal)...)
		default:
			out = append(out, f.raw...)
		}
	}
	return out, changed, nil
}

func parseARPCPayloadBounds(body []byte) (lengthOffset, payloadOffset, payloadEnd int, err error) {
	if len(body) < 2 {
		return 0, 0, 0, errors.New("ARPC body too short")
	}

	offset := 2 // version
	for range 3 {
		if offset+2 > len(body) {
			return 0, 0, 0, errors.New("truncated ARPC string length")
		}
		length := int(binary.BigEndian.Uint16(body[offset : offset+2]))
		offset += 2
		if length > len(body)-offset {
			return 0, 0, 0, errors.New("truncated ARPC string")
		}
		offset += length
	}

	const functionAndLengthBytes = 8
	if offset+functionAndLengthBytes > len(body) {
		return 0, 0, 0, errors.New("truncated ARPC header")
	}
	lengthOffset = offset + 4
	payloadOffset = lengthOffset + 4
	payloadLength := uint64(binary.BigEndian.Uint32(body[lengthOffset:payloadOffset]))
	if payloadLength == 0 || payloadLength > uint64(len(body)-payloadOffset) {
		return 0, 0, 0, errors.New("invalid ARPC payload length")
	}
	return lengthOffset, payloadOffset, payloadOffset + int(payloadLength), nil
}

func patchARPCFrame(body []byte, c wlocCoords) ([]byte, patchStats, error) {
	lengthOffset, payloadOffset, payloadEnd, err := parseARPCPayloadBounds(body)
	if err != nil {
		return nil, patchStats{}, err
	}

	var st patchStats
	payload := body[payloadOffset:payloadEnd]
	newPayload, changed, err := patchWlocPayload(payload, c, &st)
	if err != nil {
		return nil, patchStats{}, err
	}
	if !changed || bytes.Equal(newPayload, payload) {
		return nil, patchStats{}, errors.New("ARPC envelope has no patchable wloc payload")
	}

	var lenBytes [4]byte
	binary.BigEndian.PutUint32(lenBytes[:], uint32(len(newPayload)))
	out := append(cloneBytes(body[:lengthOffset]), lenBytes[:]...)
	out = append(out, newPayload...)
	out = append(out, body[payloadEnd:]...)
	return out, st, nil
}

func patchMarkerFrame(body []byte, c wlocCoords) ([]byte, patchStats, error) {
	markerOffset := bytes.Index(body, wlocMarker)
	if markerOffset < 0 {
		return nil, patchStats{}, errors.New("wloc marker not found")
	}

	lengthOffset := markerOffset + len(wlocMarker)
	payloadOffset := lengthOffset + 2
	if payloadOffset > len(body) {
		return nil, patchStats{}, errors.New("truncated marker frame")
	}
	payloadLength := int(binary.BigEndian.Uint16(body[lengthOffset:payloadOffset]))
	if payloadLength == 0 || payloadLength > len(body)-payloadOffset {
		return nil, patchStats{}, errors.New("invalid marker payload length")
	}
	payloadEnd := payloadOffset + payloadLength

	var st patchStats
	payload := body[payloadOffset:payloadEnd]
	newPayload, changed, err := patchWlocPayload(payload, c, &st)
	if err != nil {
		return nil, patchStats{}, err
	}
	if !changed || bytes.Equal(newPayload, payload) {
		return nil, patchStats{}, errors.New("marker frame has no patchable wloc payload")
	}
	if len(newPayload) > 65535 {
		return nil, patchStats{}, errors.New("patched marker payload too large")
	}

	var lenBytes [2]byte
	binary.BigEndian.PutUint16(lenBytes[:], uint16(len(newPayload)))
	out := append(cloneBytes(body[:lengthOffset]), lenBytes[:]...)
	out = append(out, newPayload...)
	out = append(out, body[payloadEnd:]...)
	return out, st, nil
}

func patchFrame(body []byte, offset int, c wlocCoords, st *patchStats) ([]byte, patchStats, error) {
	if len(body) < offset+10 {
		return nil, *st, fmt.Errorf("body too short: %d, base=%d", len(body), offset)
	}
	length := int(binary.BigEndian.Uint16(body[offset+8 : offset+10]))
	if length <= 0 {
		return nil, *st, errors.New("invalid empty frame length")
	}
	if offset+10+length > len(body) {
		return nil, *st, fmt.Errorf("invalid frame length %d at %d for %d", length, offset, len(body))
	}

	prefix := cloneBytes(body[:offset+8])
	payload := cloneBytes(body[offset+10 : offset+10+length])
	suffix := cloneBytes(body[offset+10+length:])
	before := *st
	newPayload, changed, err := patchWlocPayload(payload, c, st)
	if err != nil || !changed || (int(st.WiFi-before.WiFi)+int(st.Cell-before.Cell)+int(st.Locations-before.Locations)) <= 0 || bytes.Equal(newPayload, payload) {
		*st = before
		if err != nil {
			return nil, *st, err
		}
		return nil, *st, errors.New("frame parsed but no patchable wloc payload")
	}
	if len(newPayload) > 65535 {
		*st = before
		return nil, *st, errors.New("patched payload too large")
	}

	var lenBytes [2]byte
	binary.BigEndian.PutUint16(lenBytes[:], uint16(len(newPayload)))
	out := append(prefix, lenBytes[:]...)
	out = append(out, newPayload...)
	out = append(out, suffix...)
	return out, *st, nil
}

func patchWlocBody(body []byte, c wlocCoords) ([]byte, patchStats, error) {
	if out, st, err := patchARPCFrame(body, c); err == nil {
		return out, st, nil
	}
	if out, st, err := patchMarkerFrame(body, c); err == nil {
		return out, st, nil
	}

	var st patchStats
	offsets := []int{0, 2, 4, 6, 8, 10, 12, 14, 16}
	seen := map[int]bool{}
	for _, o := range offsets {
		seen[o] = true
	}
	limit := minInt(96, maxInt(0, len(body)-10))
	for i := 0; i <= limit; i++ {
		if !seen[i] {
			offsets = append(offsets, i)
		}
	}

	for _, offset := range offsets {
		local := st
		out, _, err := patchFrame(body, offset, c, &local)
		if err == nil {
			return out, local, nil
		}
		st = local
	}

	fallbackLimit := minInt(256, len(body))
	for i := 0; i <= fallbackLimit; i++ {
		local := patchStats{}
		payload := body[i:]
		newPayload, changed, err := patchWlocPayload(payload, c, &local)
		if err == nil && changed && !bytes.Equal(newPayload, payload) {
			out := append(cloneBytes(body[:i]), newPayload...)
			return out, local, nil
		}
	}
	return nil, st, errors.New("no patchable wloc payload found")
}

func maybeGunzip(body []byte) ([]byte, bool, error) {
	if len(body) >= 2 && body[0] == 0x1f && body[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return nil, true, err
		}
		defer zr.Close()
		out, err := io.ReadAll(zr)
		return out, true, err
	}
	return body, false, nil
}

func patchResponseBody(body []byte, c wlocCoords) ([]byte, patchStats, error) {
	decompressed, wasGzip, err := maybeGunzip(body)
	if err != nil {
		return nil, patchStats{}, err
	}
	patched, stats, err := patchWlocBody(decompressed, c)
	if err != nil {
		return nil, patchStats{}, err
	}
	_ = wasGzip
	return patched, stats, nil
}

func makeTestWlocBody() []byte {
	var loc []byte
	loc = append(loc, writeTag(1, wireVarint)...)
	loc = append(loc, writeVarint(100)...)
	loc = append(loc, writeTag(2, wireVarint)...)
	loc = append(loc, writeVarint(200)...)
	loc = append(loc, writeTag(3, wireVarint)...)
	loc = append(loc, writeVarint(25)...)

	mac := []byte("aa:bb:cc:dd:ee:ff")
	var device []byte
	device = append(device, writeLengthDelimited(1, mac)...)
	device = append(device, writeLengthDelimited(2, loc)...)

	payload := writeLengthDelimited(2, device)

	magic := []byte{0, 1, 0, 0, 0, 1, 0, 0}
	var lenBytes [2]byte
	binary.BigEndian.PutUint16(lenBytes[:], uint16(len(payload)))
	var out []byte
	out = append(out, magic...)
	out = append(out, lenBytes[:]...)
	out = append(out, payload...)
	return out
}
