package main

import (
	"math"
	"testing"
)

// distanceMeters 用等距圆柱投影估算两点之间的距离，足够校验几十米量级的抖动。
func distanceMeters(lat1, lon1, lat2, lon2 float64) float64 {
	dLat := (lat2 - lat1) * metersPerDegreeLatitude
	dLon := (lon2 - lon1) * metersPerDegreeLatitude * math.Cos(lat1*math.Pi/180)
	return math.Hypot(dLat, dLon)
}

func TestDriftDisabledKeepsCoordinate(t *testing.T) {
	lat, lon := driftCoordinates(22.281508, 114.174700, 0)
	if lat != 22.281508 || lon != 114.174700 {
		t.Fatalf("半径为 0 时不应改动坐标，得到 %f,%f", lat, lon)
	}
}

func TestDriftStaysWithinRadius(t *testing.T) {
	const (
		baseLat = 22.281508
		baseLon = 114.174700
	)

	for _, radius := range motionRadiusSteps {
		if radius == 0 {
			continue
		}
		for i := 0; i < 500; i++ {
			lat, lon := driftCoordinates(baseLat, baseLon, radius)
			distance := distanceMeters(baseLat, baseLon, lat, lon)
			// 留一点浮点余量，1e-6 米远小于任何实际精度。
			if distance > float64(radius)+1e-6 {
				t.Fatalf("半径 %d 米时抖动到 %.6f 米，超出范围", radius, distance)
			}
		}
	}
}

func TestDriftActuallyMoves(t *testing.T) {
	const (
		baseLat = 22.281508
		baseLon = 114.174700
	)

	moved := false
	for i := 0; i < 50; i++ {
		lat, lon := driftCoordinates(baseLat, baseLon, 20)
		if lat != baseLat || lon != baseLon {
			moved = true
			break
		}
	}
	if !moved {
		t.Fatal("开启抖动后坐标始终没有变化")
	}
}

func TestNormalizeMotionRadius(t *testing.T) {
	cases := map[int]int{
		0: 0, 5: 5, 10: 10, 20: 20,
		// 未支持的档位一律归零，避免上层传进离谱的半径。
		1: 0, 7: 0, 50: 0, -10: 0, 1000000: 0,
	}
	for input, expected := range cases {
		if got := normalizeMotionRadius(input); got != expected {
			t.Fatalf("normalizeMotionRadius(%d) = %d，期望 %d", input, got, expected)
		}
	}
}

func TestLocationHostsCoverage(t *testing.T) {
	// 用户报告过的 5 个核心端点必须始终在列。
	required := []string{
		"gs-loc.apple.com",
		"gs-loc-cn.apple.com",
		"gsp-ssl.ls.apple.com",
		"bluedot.is.autonavi.com",
		"bluedot.is.autonavi.com.gds.alibabadns.com",
	}
	for _, host := range required {
		if !isLocationHost(host) {
			t.Fatalf("缺少必要端点: %s", host)
		}
	}

	// 新版系统把定位查询分散到这些 gsp / gspe 主机上。
	extra := []string{
		"gsp10-ssl.ls.apple.com",
		"gsp10-ssl.apple.com",
		"gsp64-ssl.ls.apple.com",
		"gspe1-ssl.ls.apple.com",
		"gspe19-ssl.ls.apple.com",
		"gspe19-2-ssl.ls.apple.com",
		"gspe35-ssl.ls.apple.com",
		"gspe79-ssl.ls.apple.com",
		"gspe85-ssl.ls.apple.com",
	}
	for _, host := range extra {
		if !isLocationHost(host) {
			t.Fatalf("缺少补充端点: %s", host)
		}
	}
}

func TestLocationHostNormalization(t *testing.T) {
	if !isLocationHost("GS-LOC.APPLE.COM:443") {
		t.Fatal("应支持大小写与端口号")
	}
	if !isLocationHost("gs-loc.apple.com.") {
		t.Fatal("应支持尾部点号")
	}
	if isLocationHost("www.apple.com") {
		t.Fatal("不应把普通 Apple 域名拉进中间人")
	}
	if isLocationHost("apple.com") {
		t.Fatal("不应把裸 apple.com 拉进中间人")
	}
}

func TestLooksLikeLocationHostCatchesRotatingEndpoints(t *testing.T) {
	// Apple 会在一大批带编号的 gsp/gspe 主机之间轮换，白名单不可能穷举。
	// 漏掉的那些会把真实坐标原样透传，必须能被识别出来并留日志，
	// 否则「用着用着跳回真实位置」这件事在设备上完全不可见。
	rotating := []string{
		"gsp13-ssl.ls.apple.com",
		"gsp27-ssl.apple.com",
		"gspe42-ssl.ls.apple.com",
		"gspe7-2-ssl.ls.apple.com",
	}
	for _, host := range rotating {
		if isLocationHost(host) {
			t.Fatalf("%s 已进白名单，用例需要换一个未收录的主机", host)
		}
		if !looksLikeLocationHost(host) {
			t.Fatalf("应识别为疑似定位端点: %s", host)
		}
	}

	// 白名单里的主机由 isLocationHost 负责，不该再被当成「漏网」。
	for _, host := range locationHosts {
		if looksLikeLocationHost(host) {
			t.Fatalf("已在白名单中的 %s 不应被判定为漏网", host)
		}
	}
}

func TestLooksLikeLocationHostDoesNotOverreach(t *testing.T) {
	// 形状相近的非定位域名不能被误判，否则日志会被噪声淹没。
	unrelated := []string{
		"www.apple.com",
		"apple.com",
		"id.apple.com",
		"push.apple.com",
		"gs-loc.apple.com.evil.com",
		"notgspe-ssl.ls.apple.com",
	}
	for _, host := range unrelated {
		if looksLikeLocationHost(host) {
			t.Fatalf("不应误判为定位端点: %s", host)
		}
	}
}

