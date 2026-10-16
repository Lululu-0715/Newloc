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

// 本文件负责把 Apple WLOC 响应体里的位置条目改写成目标坐标。
//
// 结构摘要（基于对抓包样本的逆向，字段号来自实测）：
//
//	响应体
//	├── 可能的信封层
//	│   ├── ARPC 信封：version + 3 个带长度前缀的字符串 + functionId + payloadLen + payload
//	│   └── marker 信封：magic {00 00 00 01 00 00} + uint16 payloadLen + payload
//	└── wloc 载荷
//	    ├── field 2  (WiFi 设备列表)
//	    │   └── 每个设备：field 1 = MAC 字符串，field 2 = 位置条目
//	    └── field 22 / 24 (蜂窝基站响应)
//	        └── 每段：field 5 = 位置条目
//
// 位置条目内部：field 1 = 纬度(×1e8 定点)，field 2 = 经度(×1e8 定点)，
// field 3 = 精度(米)。三者都是 varint。

// wlocTarget 是要写入的目标坐标。
type wlocTarget struct {
	Latitude  float64
	Longitude float64
	Accuracy  int
	// MotionEnabled 为真时额外写入运动状态字段（field 11/12），
	// 让系统认为设备处于「静止」状态，避免定位被运动状态推断覆盖。
	MotionEnabled bool
}

// 运动状态模拟常量。实测这两个值对应 iOS 的 stationary 状态。
const (
	motionActivityType       = 63
	motionActivityConfidence = 467
)

// patchStats 记录一次改写改了哪些内容，用于诊断日志。
type patchStats struct {
	WiFiDevices  int
	CellSections int
	Locations    int
	Skipped      int
}

func (s patchStats) total() int {
	return s.WiFiDevices + s.CellSections + s.Locations
}

// MAC 地址格式：六组 1-2 位十六进制，冒号分隔。
var macPattern = regexp.MustCompile(`^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$`)

// marker 信封的魔数。
var markerMagic = []byte{0x00, 0x00, 0x00, 0x01, 0x00, 0x00}

// encodeCoordinate 把十进制度转换成 WLOC 使用的定点整数（度 × 1e8）。
func encodeCoordinate(degrees float64) int64 {
	return int64(math.Round(degrees * 1e8))
}

// patchLocationEntry 改写单条位置条目。返回改写后的字节和是否发生改动。
// 如果条目里没有同时出现纬度和经度字段，认为它不是一个位置条目，返回未改动。
func patchLocationEntry(entry []byte, target wlocTarget) ([]byte, bool, error) {
	fields, err := decodeFields(entry)
	if err != nil {
		return entry, false, err
	}

	if !hasVarintField(fields, 1) || !hasVarintField(fields, 2) {
		return entry, false, nil
	}

	latValue := uint64(encodeCoordinate(target.Latitude))
	lonValue := uint64(encodeCoordinate(target.Longitude))
	accuracyValue := uint64(target.Accuracy)

	out := make([]byte, 0, len(entry)+16)
	changed := false
	sawMotionType := false
	sawMotionConfidence := false

	for _, f := range fields {
		switch {
		case f.number == 1 && f.wireType == wireVarint:
			rewritten := appendVarintField(nil, 1, latValue)
			changed = changed || !bytes.Equal(rewritten, f.raw)
			out = append(out, rewritten...)

		case f.number == 2 && f.wireType == wireVarint:
			rewritten := appendVarintField(nil, 2, lonValue)
			changed = changed || !bytes.Equal(rewritten, f.raw)
			out = append(out, rewritten...)

		case f.number == 3 && f.wireType == wireVarint:
			rewritten := appendVarintField(nil, 3, accuracyValue)
			changed = changed || !bytes.Equal(rewritten, f.raw)
			out = append(out, rewritten...)

		// 运动状态字段只在显式开启时改写，其余情况保持原样，
		// 否则会破坏系统对运动状态的判断。
		case target.MotionEnabled && f.number == 11 && f.wireType == wireVarint:
			sawMotionType = true
			rewritten := appendVarintField(nil, 11, motionActivityType)
			changed = changed || !bytes.Equal(rewritten, f.raw)
			out = append(out, rewritten...)

		case target.MotionEnabled && f.number == 12 && f.wireType == wireVarint:
			sawMotionConfidence = true
			rewritten := appendVarintField(nil, 12, motionActivityConfidence)
			changed = changed || !bytes.Equal(rewritten, f.raw)
			out = append(out, rewritten...)

		default:
			out = append(out, f.raw...)
		}
	}

	// 原条目里没有运动状态字段时补上。
	if target.MotionEnabled && !sawMotionType {
		out = appendVarintField(out, 11, motionActivityType)
		changed = true
	}
	if target.MotionEnabled && !sawMotionConfidence {
		out = appendVarintField(out, 12, motionActivityConfidence)
		changed = true
	}

	return out, changed, nil
}

// patchWiFiDevice 处理一个 WiFi 设备条目：只有 field 1 是合法 MAC 时才
// 认定它确实是设备记录，然后改写其 field 2 中的位置条目。
func patchWiFiDevice(device []byte, target wlocTarget, stats *patchStats) ([]byte, bool, error) {
	fields, err := decodeFields(device)
	if err != nil {
		return device, false, err
	}

	isDevice := false
	for _, f := range fields {
		if f.number == 1 && f.wireType == wireLengthDelim && macPattern.Match(f.value) {
			isDevice = true
			break
		}
	}
	if !isDevice {
		return device, false, nil
	}

	out := make([]byte, 0, len(device))
	changed := false
	for _, f := range fields {
		if f.number == 2 && f.wireType == wireLengthDelim {
			patched, subChanged, err := patchLocationEntry(f.value, target)
			if err != nil {
				stats.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
				stats.Locations++
			}
			out = appendLengthDelimited(out, 2, patched)
			continue
		}
		out = append(out, f.raw...)
	}

	if changed {
		stats.WiFiDevices++
	}
	return out, changed, nil
}

// patchCellSection 处理一段蜂窝基站响应：改写其 field 5 中的位置条目。
func patchCellSection(section []byte, target wlocTarget, stats *patchStats) ([]byte, bool, error) {
	fields, err := decodeFields(section)
	if err != nil {
		return section, false, err
	}

	out := make([]byte, 0, len(section))
	changed := false
	for _, f := range fields {
		if f.number == 5 && f.wireType == wireLengthDelim {
			patched, subChanged, err := patchLocationEntry(f.value, target)
			if err != nil {
				stats.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
				stats.Locations++
			}
			out = appendLengthDelimited(out, 5, patched)
			continue
		}
		out = append(out, f.raw...)
	}

	if changed {
		stats.CellSections++
	}
	return out, changed, nil
}

// patchWlocPayload 处理 wloc 载荷本体，分发到 WiFi 和蜂窝两条分支。
func patchWlocPayload(payload []byte, target wlocTarget, stats *patchStats) ([]byte, bool, error) {
	fields, err := decodeFields(payload)
	if err != nil {
		return payload, false, err
	}

	out := make([]byte, 0, len(payload))
	changed := false

	for _, f := range fields {
		switch {
		case f.number == 2 && f.wireType == wireLengthDelim:
			patched, subChanged, err := patchWiFiDevice(f.value, target, stats)
			if err != nil {
				stats.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
			}
			out = appendLengthDelimited(out, 2, patched)

		case (f.number == 22 || f.number == 24) && f.wireType == wireLengthDelim:
			patched, subChanged, err := patchCellSection(f.value, target, stats)
			if err != nil {
				stats.Skipped++
				out = append(out, f.raw...)
				continue
			}
			if subChanged {
				changed = true
			}
			out = appendLengthDelimited(out, f.number, patched)

		default:
			out = append(out, f.raw...)
		}
	}

	return out, changed, nil
}

// reencodeFrame 把改写后的载荷按 uint16 长度前缀回填。
// 前缀位于 lengthOffset，载荷紧随其后。
func reencodeFrame(body []byte, lengthOffset int, payload []byte) ([]byte, error) {
	payloadOffset := lengthOffset + 2
	if payloadOffset > len(body) {
		return nil, errors.New("长度前缀位置越界")
	}
	if len(payload) > 65535 {
		return nil, errors.New("改写后载荷超过 uint16 上限")
	}

	var lengthBytes [2]byte
	binary.BigEndian.PutUint16(lengthBytes[:], uint16(len(payload)))

	out := make([]byte, 0, len(body)-0+len(payload))
	out = append(out, body[:lengthOffset]...)
	out = append(out, lengthBytes[:]...)
	out = append(out, payload...)
	return out, nil
}

// patchARPCPayload 尝试按 ARPC 信封解析并改写。
//
// ARPC 布局：1 字节 version，随后 3 个 uint16 长度前缀字符串，
// 然后 functionId(4) + payloadLen(4) + payload。
func patchARPCPayload(body []byte, target wlocTarget) ([]byte, patchStats, error) {
	if len(body) < 2 {
		return nil, patchStats{}, errors.New("ARPC 体过短")
	}

	cursor := 2 // 跳过 version 字段
	for i := 0; i < 3; i++ {
		if cursor+2 > len(body) {
			return nil, patchStats{}, errors.New("ARPC 字符串长度被截断")
		}
		length := int(binary.BigEndian.Uint16(body[cursor : cursor+2]))
		cursor += 2
		if length > len(body)-cursor {
			return nil, patchStats{}, errors.New("ARPC 字符串被截断")
		}
		cursor += length
	}

	const functionAndLengthBytes = 8
	if cursor+functionAndLengthBytes > len(body) {
		return nil, patchStats{}, errors.New("ARPC 头被截断")
	}

	lengthOffset := cursor + 4
	payloadOffset := lengthOffset + 4
	payloadLength := uint64(binary.BigEndian.Uint32(body[lengthOffset:payloadOffset]))
	if payloadLength == 0 || payloadLength > uint64(len(body)-payloadOffset) {
		return nil, patchStats{}, errors.New("ARPC 载荷长度非法")
	}
	payloadEnd := payloadOffset + int(payloadLength)

	var stats patchStats
	patched, changed, err := patchWlocPayload(body[payloadOffset:payloadEnd], target, &stats)
	if err != nil {
		return nil, patchStats{}, err
	}
	if !changed || bytes.Equal(patched, body[payloadOffset:payloadEnd]) {
		return nil, patchStats{}, errors.New("ARPC 载荷中没有可改写的定位数据")
	}
	if len(patched) > math.MaxUint32 {
		return nil, patchStats{}, errors.New("改写后载荷超过 uint32 上限")
	}

	var lengthBytes [4]byte
	binary.BigEndian.PutUint32(lengthBytes[:], uint32(len(patched)))

	out := make([]byte, 0, len(body))
	out = append(out, body[:lengthOffset]...)
	out = append(out, lengthBytes[:]...)
	out = append(out, patched...)
	out = append(out, body[payloadEnd:]...)
	return out, stats, nil
}

// patchMarkerPayload 尝试按 marker 信封解析并改写。
func patchMarkerPayload(body []byte, target wlocTarget) ([]byte, patchStats, error) {
	magicOffset := bytes.Index(body, markerMagic)
	if magicOffset < 0 {
		return nil, patchStats{}, errors.New("未找到 marker 魔数")
	}

	lengthOffset := magicOffset + len(markerMagic)
	payloadOffset := lengthOffset + 2
	if payloadOffset > len(body) {
		return nil, patchStats{}, errors.New("marker 帧被截断")
	}

	payloadLength := int(binary.BigEndian.Uint16(body[lengthOffset:payloadOffset]))
	if payloadLength == 0 || payloadLength > len(body)-payloadOffset {
		return nil, patchStats{}, errors.New("marker 载荷长度非法")
	}
	payloadEnd := payloadOffset + payloadLength

	var stats patchStats
	patched, changed, err := patchWlocPayload(body[payloadOffset:payloadEnd], target, &stats)
	if err != nil {
		return nil, patchStats{}, err
	}
	if !changed || bytes.Equal(patched, body[payloadOffset:payloadEnd]) {
		return nil, patchStats{}, errors.New("marker 载荷中没有可改写的定位数据")
	}
	if len(patched) > 65535 {
		return nil, patchStats{}, errors.New("改写后载荷超过 uint16 上限")
	}

	out := make([]byte, 0, len(body))
	out = append(out, body[:lengthOffset]...)
	var lengthBytes [2]byte
	binary.BigEndian.PutUint16(lengthBytes[:], uint16(len(patched)))
	out = append(out, lengthBytes[:]...)
	out = append(out, patched...)
	out = append(out, body[payloadEnd:]...)
	return out, stats, nil
}

// patchAtOffset 尝试把 offset 处当作「8 字节前缀 + uint16 长度 + 载荷」的帧。
func patchAtOffset(body []byte, offset int, target wlocTarget) ([]byte, patchStats, error) {
	if len(body) < offset+10 {
		return nil, patchStats{}, fmt.Errorf("数据过短：len=%d offset=%d", len(body), offset)
	}

	length := int(binary.BigEndian.Uint16(body[offset+8 : offset+10]))
	if length <= 0 {
		return nil, patchStats{}, errors.New("帧长度为空")
	}
	if offset+10+length > len(body) {
		return nil, patchStats{}, fmt.Errorf("帧长度 %d 越界（offset=%d, len=%d）", length, offset, len(body))
	}

	var stats patchStats
	patched, changed, err := patchWlocPayload(body[offset+10:offset+10+length], target, &stats)
	if err != nil {
		return nil, patchStats{}, err
	}
	if !changed || bytes.Equal(patched, body[offset+10:offset+10+length]) {
		return nil, patchStats{}, errors.New("该偏移处没有可改写的载荷")
	}
	if len(patched) > 65535 {
		return nil, patchStats{}, errors.New("改写后载荷超过 uint16 上限")
	}

	out := make([]byte, 0, len(body))
	out = append(out, body[:offset+8]...)
	var lengthBytes [2]byte
	binary.BigEndian.PutUint16(lengthBytes[:], uint16(len(patched)))
	out = append(out, lengthBytes[:]...)
	out = append(out, patched...)
	out = append(out, body[offset+10+length:]...)
	return out, stats, nil
}

// patchWlocBody 按优先级依次尝试各种信封格式。
//
// Apple 在不同 iOS 版本 / 网络类型下使用不同的帧封装，因此这里采取
// 「先精确匹配常见格式，再按偏移量扫描，最后退化到裸载荷」的降级策略。
func patchWlocBody(body []byte, target wlocTarget) ([]byte, patchStats, error) {
	if out, stats, err := patchARPCPayload(body, target); err == nil {
		return out, stats, nil
	}
	if out, stats, err := patchMarkerPayload(body, target); err == nil {
		return out, stats, nil
	}

	// 常见偏移优先尝试，再补齐扫描范围内剩余的位置。
	limit := minInt(96, maxInt(0, len(body)-10))
	seen := make(map[int]bool, limit+16)
	offsets := make([]int, 0, limit+16)
	for _, o := range []int{0, 2, 4, 6, 8, 10, 12, 14, 16} {
		if o <= limit && !seen[o] {
			seen[o] = true
			offsets = append(offsets, o)
		}
	}
	for i := 0; i <= limit; i++ {
		if !seen[i] {
			seen[i] = true
			offsets = append(offsets, i)
		}
	}

	for _, offset := range offsets {
		if out, stats, err := patchAtOffset(body, offset, target); err == nil {
			return out, stats, nil
		}
	}

	// 最后退化：直接扫描整段数据，找第一个能解析出位置条目并发生改动的位置。
	//
	// 这一层的代价是「每个偏移都做一次完整解析」，即 O(扫描次数 × 体长)。
	// marker 信封的长度前缀是 uint16，真正的 wloc 载荷不可能超过 64 KB，
	// 所以更大的响应说明它根本不是定位响应（比如那 14 个主机返回的错误页、
	// 或别的什么内容）—— 继续扫下去只是白白烧 CPU 与内存，
	// 而这个进程同时在给定位请求当代理，卡住会直接被 locationd 判超时。
	// 因此只在体量合理时才尝试这一层。
	fallbackLimit := 0
	if len(body) <= rawScanBodyLimit {
		fallbackLimit = minInt(256, len(body))
	}
	for i := 0; i <= fallbackLimit; i++ {
		var stats patchStats
		patched, changed, err := patchWlocPayload(body[i:], target, &stats)
		if err == nil && changed && !bytes.Equal(patched, body[i:]) {
			out := make([]byte, 0, len(body)+len(patched))
			out = append(out, body[:i]...)
			out = append(out, patched...)
			return out, stats, nil
		}
	}

	return nil, patchStats{}, errors.New("未找到可改写的 WLOC 载荷")
}

// gunzipIfNeeded 在数据带 gzip 魔数时解压。返回值第二项表示是否原本是 gzip。
func gunzipIfNeeded(body []byte) ([]byte, bool, error) {
	if len(body) < 2 || body[0] != 0x1f || body[1] != 0x8b {
		return body, false, nil
	}
	reader, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return nil, true, err
	}
	defer reader.Close()
	out, err := io.ReadAll(reader)
	return out, true, err
}

// maxPatchBodyBytes 限定参与改写的响应体上限，超过则直接放行，
// 避免在超大响应上耗费内存和 CPU。
const maxPatchBodyBytes = 1 << 20

// rawScanBodyLimit 是「裸载荷逐偏移扫描」这一层允许的最大体长。
// 超过它就不再尝试：marker 信封用 uint16 表示载荷长度（上限 64 KB），
// 比这更大的内容不可能是 wloc 载荷。
const rawScanBodyLimit = 1 << 16

// rewriteResponseBody 是给 HTTPS 代理层调用的入口。
func rewriteResponseBody(body []byte, target wlocTarget) ([]byte, patchStats, error) {
	decompressed, _, err := gunzipIfNeeded(body)
	if err != nil {
		return nil, patchStats{}, err
	}
	return patchWlocBody(decompressed, target)
}
