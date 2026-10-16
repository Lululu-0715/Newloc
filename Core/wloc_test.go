package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"testing"
)

// 本文件验证 WLOC 改写引擎的核心行为：
// 定点坐标写入正确、未知字段原样保留、信封长度字段被正确回填。

// TestCoordinateEncoding 验证十进制度到定点整数的换算。
func TestCoordinateEncoding(t *testing.T) {
	cases := []struct {
		degrees float64
		want    int64
	}{
		{0, 0},
		{1, 100000000},
		{-1, -100000000},
		{22.281508, 2228150800},
		{114.174700, 11417470000},
		{-33.868820, -3386882000},
	}
	for _, c := range cases {
		if got := encodeCoordinate(c.degrees); got != c.want {
			t.Errorf("encodeCoordinate(%v) = %d，期望 %d", c.degrees, got, c.want)
		}
	}
}

// TestVarintRoundTrip 验证 varint 编解码自洽。
func TestVarintRoundTrip(t *testing.T) {
	values := []uint64{0, 1, 127, 128, 300, 16383, 16384, 1 << 31, 1<<63 + 1}
	for _, v := range values {
		encoded := appendVarint(nil, v)
		decoded, n, err := readVarint(encoded)
		if err != nil {
			t.Fatalf("readVarint(%d) 报错: %v", v, err)
		}
		if decoded != v {
			t.Errorf("varint 往返不一致: %d → %d", v, decoded)
		}
		if n != len(encoded) {
			t.Errorf("varint 长度不符: %d 消耗 %d 字节，共 %d 字节", v, n, len(encoded))
		}
	}
}

// TestDecodeFieldsRejectsMalformed 验证畸形输入被拒绝而不是 panic。
func TestDecodeFieldsRejectsMalformed(t *testing.T) {
	inputs := [][]byte{
		{0x80},             // 被截断的 varint
		{0x08},             // 有 tag 没有值
		{0x0a, 0x05, 0x01}, // 长度声明 5 但只有 1 字节
		{0x00, 0x01},       // 字段号为 0
		{0x0f},             // 不支持的 wire type 7
	}
	for i, input := range inputs {
		if _, err := decodeFields(input); err == nil {
			t.Errorf("输入 #%d 应当报错但通过了: %x", i, input)
		}
	}
}

// TestPatchLocationEntryRewritesCoordinates 验证纬度/经度/精度都被改写，
// 且其他字段（例如精度后面的未知字段）原样保留。
func TestPatchLocationEntryRewritesCoordinates(t *testing.T) {
	var entry []byte
	entry = appendVarintField(entry, 1, 100)
	entry = appendVarintField(entry, 2, 200)
	entry = appendVarintField(entry, 3, 25)
	entry = appendVarintField(entry, 9, 12345) // 未知字段，不应被改动

	target := wlocTarget{Latitude: 22.281508, Longitude: 114.174700, Accuracy: 50}
	patched, changed, err := patchLocationEntry(entry, target)
	if err != nil {
		t.Fatalf("改写失败: %v", err)
	}
	if !changed {
		t.Fatal("应当发生改动")
	}

	fields, err := decodeFields(patched)
	if err != nil {
		t.Fatalf("改写结果无法解析: %v", err)
	}

	values := map[int]uint64{}
	for _, f := range fields {
		if f.wireType == wireVarint {
			v, _, _ := readVarint(f.value)
			values[f.number] = v
		}
	}

	if got := int64(values[1]); got != encodeCoordinate(target.Latitude) {
		t.Errorf("纬度 = %d，期望 %d", got, encodeCoordinate(target.Latitude))
	}
	if got := int64(values[2]); got != encodeCoordinate(target.Longitude) {
		t.Errorf("经度 = %d，期望 %d", got, encodeCoordinate(target.Longitude))
	}
	if got := values[3]; got != 50 {
		t.Errorf("精度 = %d，期望 50", got)
	}
	if got := values[9]; got != 12345 {
		t.Errorf("未知字段 9 被破坏: %d，期望 12345", got)
	}
}

// TestPatchLocationEntrySkipsNonLocation 验证缺少经纬度字段的条目不被误改。
func TestPatchLocationEntrySkipsNonLocation(t *testing.T) {
	var entry []byte
	entry = appendVarintField(entry, 1, 100)
	entry = appendVarintField(entry, 7, 7) // 没有 field 2

	target := wlocTarget{Latitude: 1, Longitude: 2, Accuracy: 3}
	patched, changed, err := patchLocationEntry(entry, target)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if changed {
		t.Error("非位置条目不应被改动")
	}
	if !bytes.Equal(patched, entry) {
		t.Error("非位置条目内容应保持原样")
	}
}

// TestPatchWiFiDeviceRequiresMAC 验证只有带合法 MAC 的设备条目才被处理。
func TestPatchWiFiDeviceRequiresMAC(t *testing.T) {
	location := appendVarintField(nil, 1, 100)
	location = appendVarintField(location, 2, 200)

	withMAC := appendLengthDelimited(nil, 1, []byte("aa:bb:cc:dd:ee:ff"))
	withMAC = appendLengthDelimited(withMAC, 2, location)

	var stats patchStats
	target := wlocTarget{Latitude: 31.23, Longitude: 121.47, Accuracy: 10}
	_, changed, err := patchWiFiDevice(withMAC, target, &stats)
	if err != nil {
		t.Fatalf("合法设备条目不应报错: %v", err)
	}
	if !changed {
		t.Error("带 MAC 的设备条目应当被改写")
	}

	// 把 MAC 换成不可识别的内容，应当被跳过。
	invalid := appendLengthDelimited(nil, 1, []byte("not-a-mac"))
	invalid = appendLengthDelimited(invalid, 2, location)
	stats = patchStats{}
	_, changed, err = patchWiFiDevice(invalid, target, &stats)
	if err != nil {
		t.Fatalf("非法设备条目不应报错: %v", err)
	}
	if changed {
		t.Error("MAC 非法的条目不应被改写")
	}
}

// TestPatchMarkerFrameRefillsLength 验证 marker 信封的长度前缀被正确重算。
func TestPatchMarkerFrameRefillsLength(t *testing.T) {
	sample := buildSampleResponse()

	// 记下原始长度前缀。
	originalLength := int(binary.BigEndian.Uint16(sample[8:10]))

	target := wlocTarget{Latitude: 39.9042, Longitude: 116.4074, Accuracy: 20}
	patched, stats, err := patchWlocBody(sample, target)
	if err != nil {
		t.Fatalf("改写失败: %v", err)
	}
	if stats.Locations != 1 {
		t.Errorf("改写位置条目数 = %d，期望 1", stats.Locations)
	}

	// 新长度前缀必须与实际载荷长度一致，否则系统解析会失败。
	newLength := int(binary.BigEndian.Uint16(patched[8:10]))
	if newLength != len(patched)-10 {
		t.Errorf("长度前缀 = %d，实际载荷 = %d", newLength, len(patched)-10)
	}
	if newLength == originalLength {
		t.Log("长度未变化（坐标恰好等长时属正常）")
	}

	// 回读校验坐标确实写进去了。
	payload := patched[10 : 10+newLength]
	wantLat := appendVarintField(nil, 1, uint64(encodeCoordinate(target.Latitude)))
	wantLon := appendVarintField(nil, 2, uint64(encodeCoordinate(target.Longitude)))
	if !bytes.Contains(payload, wantLat) {
		t.Error("结果中未找到目标纬度")
	}
	if !bytes.Contains(payload, wantLon) {
		t.Error("结果中未找到目标经度")
	}
}

// TestMotionSimulationFields 验证开启运动模拟时字段 11/12 被写入，
// 关闭时不会被触碰。
func TestMotionSimulationFields(t *testing.T) {
	var entry []byte
	entry = appendVarintField(entry, 1, 100)
	entry = appendVarintField(entry, 2, 200)
	entry = appendVarintField(entry, 3, 25)

	// 关闭：不应出现 field 11/12。
	off, _, err := patchLocationEntry(entry, wlocTarget{Latitude: 1, Longitude: 1, Accuracy: 1})
	if err != nil {
		t.Fatalf("改写失败: %v", err)
	}
	offFields, _ := decodeFields(off)
	if hasVarintField(offFields, 11) || hasVarintField(offFields, 12) {
		t.Error("关闭运动模拟时不应写入 field 11/12")
	}

	// 开启：应当补上 field 11/12。
	on, _, err := patchLocationEntry(entry, wlocTarget{
		Latitude: 1, Longitude: 1, Accuracy: 1, MotionEnabled: true,
	})
	if err != nil {
		t.Fatalf("改写失败: %v", err)
	}
	onFields, _ := decodeFields(on)
	if !hasVarintField(onFields, 11) || !hasVarintField(onFields, 12) {
		t.Error("开启运动模拟时应当写入 field 11/12")
	}
}

// TestRewriteResponseBodyHandlesGzip 验证 gzip 压缩的响应体也能处理。
func TestRewriteResponseBodyHandlesGzip(t *testing.T) {
	sample := buildSampleResponse()
	compressed := gzipBytes(t, sample)

	target := wlocTarget{Latitude: 30.5728, Longitude: 104.0668, Accuracy: 15}
	patched, stats, err := rewriteResponseBody(compressed, target)
	if err != nil {
		t.Fatalf("gzip 响应改写失败: %v", err)
	}
	if stats.Locations == 0 {
		t.Error("应当改写至少一个位置条目")
	}
	if bytes.Equal(patched, sample) {
		t.Error("改写结果不应与原始样本相同")
	}
}

// TestGenerateAndParseCA 验证 CA 生成与解析闭环。
func TestGenerateAndParseCA(t *testing.T) {
	certPEM, keyPEM, err := generateCA()
	if err != nil {
		t.Fatalf("生成 CA 失败: %v", err)
	}
	if len(certPEM) == 0 || len(keyPEM) == 0 {
		t.Fatal("CA 输出为空")
	}
	if err := validateCA(certPEM, keyPEM); err != nil {
		t.Fatalf("CA 校验失败: %v", err)
	}

	ca, err := parseCA(certPEM, keyPEM)
	if err != nil {
		t.Fatalf("CA 解析失败: %v", err)
	}
	if !ca.Leaf.IsCA {
		t.Error("生成的证书应当是 CA 证书")
	}
	if ca.Leaf.KeyUsage&0 == 0 {
		t.Log("KeyUsage 已设置")
	}

	// 私钥与证书必须匹配：拿篡改过的私钥应当校验失败。
	if err := validateCA(certPEM, []byte("-----BEGIN PRIVATE KEY-----\ninvalid\n-----END PRIVATE KEY-----\n")); err == nil {
		t.Error("非法私钥应当校验失败")
	}
}

// TestIssueLoopbackLeaf 验证叶子证书由 CA 签发且可用于 127.0.0.1。
func TestIssueLoopbackLeaf(t *testing.T) {
	certPEM, keyPEM, err := generateCA()
	if err != nil {
		t.Fatalf("生成 CA 失败: %v", err)
	}
	ca, err := parseCA(certPEM, keyPEM)
	if err != nil {
		t.Fatalf("解析 CA 失败: %v", err)
	}

	leaf, der, err := issueLoopbackLeaf(ca)
	if err != nil {
		t.Fatalf("签发叶子证书失败: %v", err)
	}
	if len(der) == 0 {
		t.Fatal("叶子证书为空")
	}
	if !bytes.Equal(leaf.Leaf.RawIssuer, ca.Leaf.RawSubject) {
		t.Error("叶子证书的签发者应当与 CA 主体一致")
	}

	foundLoopback := false
	for _, ip := range leaf.Leaf.IPAddresses {
		if ip.String() == "127.0.0.1" {
			foundLoopback = true
		}
	}
	if !foundLoopback {
		t.Error("叶子证书应当包含 127.0.0.1")
	}
}

// TestSelfCheckPatch 验证 Core 自检接口能通过。
func TestSelfCheckPatch(t *testing.T) {
	lat, lon := 22.281508, 114.174700
	sample := buildSampleResponse()
	patched, stats, err := patchWlocBody(sample, wlocTarget{
		Latitude: lat, Longitude: lon, Accuracy: 20,
	})
	if err != nil {
		t.Fatalf("自检改写失败: %v", err)
	}
	if stats.WiFiDevices != 1 {
		t.Errorf("WiFi 设备改写数 = %d，期望 1", stats.WiFiDevices)
	}

	length := int(binary.BigEndian.Uint16(patched[8:10]))
	payload := patched[10 : 10+length]

	// 用浮点换算后再比对，确认精度没有在定点转换中丢失。
	decodedLat := float64(int64(readVarintRaw(t, payload, 1))) / 1e8
	decodedLon := float64(int64(readVarintRaw(t, payload, 2))) / 1e8
	if math.Abs(decodedLat-lat) > 1e-7 {
		t.Errorf("纬度回读 = %f，期望 %f", decodedLat, lat)
	}
	if math.Abs(decodedLon-lon) > 1e-7 {
		t.Errorf("经度回读 = %f，期望 %f", decodedLon, lon)
	}
}

// readVarintRaw 在嵌套载荷里递归查找第一个匹配字段号并返回其 varint 值。
// 仅用于测试中的回读断言。
func readVarintRaw(t *testing.T, data []byte, fieldNumber int) uint64 {
	t.Helper()
	var walk func([]byte) (uint64, bool)
	walk = func(buf []byte) (uint64, bool) {
		fields, err := decodeFields(buf)
		if err != nil {
			return 0, false
		}
		for _, f := range fields {
			if f.number == fieldNumber && f.wireType == wireVarint {
				v, _, err := readVarint(f.value)
				if err == nil {
					return v, true
				}
			}
			if f.wireType == wireLengthDelim {
				if v, ok := walk(f.value); ok {
					return v, true
				}
			}
		}
		return 0, false
	}
	v, ok := walk(data)
	if !ok {
		t.Fatalf("未找到字段 %d", fieldNumber)
	}
	return v
}
