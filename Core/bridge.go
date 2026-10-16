package main

// 本文件是 Go Core 与 Swift 之间的唯一接口层。
//
// 约定：
//   - 所有返回 *C.char 的函数，调用方（Swift）负责 free；
//   - 长生命周期对象（代理服务、证书服务）通过 cgo.Handle 以 uintptr 形式
//     交给 Swift 保存，销毁时必须调用对应的 stop 函数，否则会泄漏；
//   - 所有坐标一律使用 WGS-84 十进制度，坐标体系转换在 Swift 侧完成。

/*
#cgo CFLAGS: -DGOOS_ios -DNDEBUG
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/http"
	"runtime/cgo"
)

// bundlePrefix 供描述文件里的 PayloadIdentifier 使用，换名字时改这里。
const bundlePrefix = "com.fff.loc"

// ---------------------------------------------------------------------------
// 基础信息
// ---------------------------------------------------------------------------

//export locationcore_version
func locationcore_version() *C.char {
	return C.CString(coreVersion)
}

// coreVersion 是 Core 的版本号，用于 Swift 侧确认桥接层版本匹配。
const coreVersion = "1.0.0"

// ---------------------------------------------------------------------------
// 根证书
// ---------------------------------------------------------------------------

//export locationcore_generateca
func locationcore_generateca() (certOut, keyOut *C.char) {
	logEvent("开始生成 CA")
	certPEM, keyPEM, err := generateCA()
	if err != nil {
		logEvent("CA 生成失败: " + err.Error())
		return nil, nil
	}
	logEvent("CA 生成完成")
	return C.CString(string(certPEM)), C.CString(string(keyPEM))
}

//export locationcore_validateca
func locationcore_validateca(certData, keyData *C.char) C.int {
	if certData == nil || keyData == nil {
		return 0
	}
	if err := validateCA([]byte(C.GoString(certData)), []byte(C.GoString(keyData))); err != nil {
		logEvent("CA 校验失败: " + err.Error())
		return 0
	}
	return 1
}

// ---------------------------------------------------------------------------
// 拦截代理
// ---------------------------------------------------------------------------

//export locationcore_startproxy
func locationcore_startproxy(certData, keyData *C.char, lat, lon C.double, enabled C.int, accuracy C.int) C.uintptr_t {
	return locationcore_startproxyv2(certData, keyData, lat, lon, enabled, accuracy, 0)
}

//export locationcore_startproxyv2
func locationcore_startproxyv2(certData, keyData *C.char, lat, lon C.double, enabled C.int, accuracy C.int, motionRadius C.int) C.uintptr_t {
	if certData == nil || keyData == nil {
		return 0
	}
	server, err := startProxy(
		[]byte(C.GoString(certData)),
		[]byte(C.GoString(keyData)),
		float64(lat),
		float64(lon),
		enabled != 0,
		int(accuracy),
		int(motionRadius),
	)
	if err != nil {
		logEvent("代理启动失败: " + err.Error())
		return 0
	}
	return C.uintptr_t(cgo.NewHandle(server))
}

//export locationcore_stopproxy
func locationcore_stopproxy(handle C.uintptr_t) C.int {
	server, h, ok := proxyHandle(handle)
	if !ok {
		logEvent("停止代理失败: 句柄无效")
		return 1
	}
	h.Delete()
	if err := stopProxy(server); err != nil {
		logEvent("停止代理失败: " + err.Error())
		return 2
	}
	logEvent("代理已停止")
	return 0
}

func proxyHandle(handle C.uintptr_t) (server *http.Server, h cgo.Handle, ok bool) {
	if handle == 0 {
		return nil, 0, false
	}
	// cgo.Handle 在句柄已被释放时取值会 panic，这里统一兜住。
	defer func() {
		if recover() != nil {
			server, h, ok = nil, 0, false
		}
	}()
	h = cgo.Handle(handle)
	value, ok := h.Value().(*http.Server)
	return value, h, ok
}

//export locationcore_setpatchconfig
func locationcore_setpatchconfig(lat, lon C.double, enabled C.int, accuracy C.int, motionRadius C.int) {
	setSpoofConfig(float64(lat), float64(lon), enabled != 0, int(accuracy), int(motionRadius))
}

//export locationcore_setcoords
func locationcore_setcoords(lat, lon C.double, enabled C.int, accuracy C.int) {
	locationcore_setpatchconfig(lat, lon, enabled, accuracy, 0)
}

//export locationcore_getcoords
func locationcore_getcoords() (lat, lon C.double, enabled C.int) {
	latValue, lonValue, isEnabled, _, _ := currentSpoofConfig()
	enabled = 0
	if isEnabled {
		enabled = 1
	}
	return C.double(latValue), C.double(lonValue), enabled
}

// ---------------------------------------------------------------------------
// 日志
// ---------------------------------------------------------------------------

//export locationcore_drainlogs
func locationcore_drainlogs() *C.char {
	s := drainLogs()
	if s == "" {
		return nil
	}
	return C.CString(s)
}

// ---------------------------------------------------------------------------
// 证书服务
// ---------------------------------------------------------------------------

//export locationcore_startcertservice
func locationcore_startcertservice(certData, keyData *C.char) C.uintptr_t {
	if certData == nil || keyData == nil {
		return 0
	}
	logEvent("请求启动证书服务")
	service, err := startCertificateService([]byte(C.GoString(certData)), []byte(C.GoString(keyData)))
	if err != nil {
		logEvent("证书服务启动失败: " + err.Error())
		return 0
	}
	logEvent("证书服务已启动 http=" + service.DownloadURL() + " probe=" + service.ProbeURL())
	return C.uintptr_t(cgo.NewHandle(service))
}

func certServiceHandle(handle C.uintptr_t) (service *certificateService, h cgo.Handle, ok bool) {
	if handle == 0 {
		return nil, 0, false
	}
	defer func() {
		if recover() != nil {
			service, h, ok = nil, 0, false
		}
	}()
	h = cgo.Handle(handle)
	value, ok := h.Value().(*certificateService)
	return value, h, ok
}

//export locationcore_certservice_httpport
func locationcore_certservice_httpport(handle C.uintptr_t) C.int {
	service, _, ok := certServiceHandle(handle)
	if !ok {
		return 0
	}
	return C.int(service.HTTPPort())
}

//export locationcore_certservice_httpsport
func locationcore_certservice_httpsport(handle C.uintptr_t) C.int {
	service, _, ok := certServiceHandle(handle)
	if !ok {
		return 0
	}
	return C.int(service.HTTPSPort())
}

//export locationcore_certservice_leafsha256
func locationcore_certservice_leafsha256(handle C.uintptr_t) *C.char {
	service, _, ok := certServiceHandle(handle)
	if !ok {
		return nil
	}
	return C.CString(service.LeafSHA256())
}

//export locationcore_stopcertservice
func locationcore_stopcertservice(handle C.uintptr_t) C.int {
	service, h, ok := certServiceHandle(handle)
	if !ok {
		return 1
	}
	h.Delete()
	if err := service.Close(); err != nil {
		return 2
	}
	return 0
}

// ---------------------------------------------------------------------------
// 自检
// ---------------------------------------------------------------------------

//export locationcore_testpatch
func locationcore_testpatch(lat, lon C.double, accuracy C.int) *C.char {
	target := wlocTarget{
		Latitude:  float64(lat),
		Longitude: float64(lon),
		Accuracy:  int(accuracy),
	}
	sample := buildSampleResponse()
	patched, stats, err := patchWlocBody(sample, target)
	if err != nil {
		return C.CString("error: " + err.Error())
	}
	if stats.Locations == 0 {
		return C.CString("error: 未找到位置条目")
	}
	if len(patched) < 10 {
		return C.CString("error: 改写结果过短")
	}

	// 回读校验：确认写入的定点坐标确实出现在结果里。
	newLength := int(binary.BigEndian.Uint16(patched[8:10]))
	if newLength <= 0 || 10+newLength > len(patched) {
		return C.CString("error: 改写结果长度非法")
	}
	payload := patched[10 : 10+newLength]
	wantLat := appendVarintField(nil, 1, uint64(encodeCoordinate(target.Latitude)))
	wantLon := appendVarintField(nil, 2, uint64(encodeCoordinate(target.Longitude)))
	if !bytes.Contains(payload, wantLat) {
		return C.CString("error: 纬度回读不一致")
	}
	if !bytes.Contains(payload, wantLon) {
		return C.CString("error: 经度回读不一致")
	}
	return C.CString(fmt.Sprintf("ok: lat=%f lon=%f wifi=%d cell=%d locations=%d",
		target.Latitude, target.Longitude, stats.WiFiDevices, stats.CellSections, stats.Locations))
}

//export locationcore_samplerequesthex
func locationcore_samplerequesthex() *C.char {
	return C.CString(hex.EncodeToString(buildSampleRequest()))
}

// ---------------------------------------------------------------------------
// 代理连通性验证
// ---------------------------------------------------------------------------

//export locationcore_refreshverifytoken
func locationcore_refreshverifytoken() *C.char {
	token := randomHex32()
	setVerifyToken(token)
	return C.CString(token)
}

//export locationcore_checkverifytoken
func locationcore_checkverifytoken(token *C.char) C.int {
	if token != nil && matchesVerifyToken(C.GoString(token)) {
		return 1
	}
	return 0
}

//export locationcore_isproxylistening
func locationcore_isproxylistening() C.int {
	if isProxyListening() {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// 测试样本构造
// ---------------------------------------------------------------------------

// buildSampleResponse 构造一份结构等价于真实 WLOC 响应的样本，
// 用于自检改写引擎是否正常工作。
func buildSampleResponse() []byte {
	var location []byte
	location = appendVarintField(location, 1, 100)
	location = appendVarintField(location, 2, 200)
	location = appendVarintField(location, 3, 25)

	var device []byte
	device = appendLengthDelimited(device, 1, []byte("aa:bb:cc:dd:ee:ff"))
	device = appendLengthDelimited(device, 2, location)

	payload := appendLengthDelimited(nil, 2, device)

	magic := []byte{0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00}
	var lengthBytes [2]byte
	binary.BigEndian.PutUint16(lengthBytes[:], uint16(len(payload)))

	out := make([]byte, 0, len(magic)+2+len(payload))
	out = append(out, magic...)
	out = append(out, lengthBytes[:]...)
	out = append(out, payload...)
	return out
}

// buildSampleRequest 构造一份带 WiFi 与基站信息的扫描请求样本，
// 仅用于自检与调试展示。
func buildSampleRequest() []byte {
	type accessPoint struct {
		mac     string
		rssi    int64
		channel int64
	}
	points := []accessPoint{
		{"aa:bb:cc:dd:ee:ff", -45, 6},
		{"11:22:33:44:55:66", -62, 11},
		{"77:88:99:00:11:22", -71, 1},
	}

	var out []byte
	for _, ap := range points {
		var device []byte
		device = appendLengthDelimited(device, 1, []byte(ap.mac))
		device = appendVarintField(device, 4, uint64(ap.rssi))
		device = appendVarintField(device, 6, uint64(ap.channel))
		out = appendLengthDelimited(out, 1, device)
	}

	var cell []byte
	cell = appendVarintField(cell, 1, 1)     // 网络制式：GSM
	cell = appendVarintField(cell, 2, 460)   // MCC：中国
	cell = appendVarintField(cell, 3, 1)     // MNC
	cell = appendVarintField(cell, 4, 15200) // LAC
	cell = appendVarintField(cell, 5, 24680) // CellID
	out = appendLengthDelimited(out, 5, cell)

	return out
}
