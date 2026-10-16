package main

import (
	"strings"
	"testing"
)

// proxyLogger 是「系统拒绝了我们的证书」这件事**唯一**的出口。
//
// 在接上它之前，goproxy 的告警只写 `os.Stderr` —— 在 iOS 上等于扔进黑洞，
// 诊断页里完全看不到。于是「开关亮着、坐标写好了、定位就是不生效」这种投诉，
// 用户和排查的人都拿不到任何线索（见 proxyLogger 的注释）。
//
// 这一组用例钉住两件事：
//   - 和定位有关的问题**一定要**留痕；
//   - 无关主机的问题**一定不要**留痕 —— 全局代理模式下无关流量很多，
//     它们会把 200 条环形缓冲刷掉，真正的问题反而查不到。
func TestProxyLoggerKeepsLocationHandshakeFailure(t *testing.T) {
	drainLogs()

	proxyLogger{}.Printf(
		"[007] WARN: Cannot handshake client %v %v\n",
		"gs-loc.apple.com",
		"tls: failed to verify certificate: x509: certificate signed by unknown authority",
	)

	logs := drainLogs()
	if !strings.Contains(logs, "TLS 握手失败") {
		t.Fatalf("定位端点的握手失败没有留痕: %q", logs)
	}
	if !strings.Contains(logs, "gs-loc.apple.com") {
		t.Fatalf("日志里应当带上主机名: %q", logs)
	}
	if strings.Contains(logs, "WARN:") {
		t.Fatalf("应当去掉 goproxy 的前缀，只留可读内容: %q", logs)
	}
}

// 白名单外的轮换端点（gsp13-ssl 之类）也算「和我们有关」——
// 它们正是「用着用着跳回真实位置」的常见原因，必须留痕。
func TestProxyLoggerKeepsRotatingEndpointHandshakeFailure(t *testing.T) {
	drainLogs()

	proxyLogger{}.Printf("[009] WARN: Cannot handshake client %v %v\n",
		"gsp13-ssl.apple.com", "tls: handshake failure")

	if logs := drainLogs(); !strings.Contains(logs, "gsp13-ssl.apple.com") {
		t.Fatalf("白名单外的轮换端点应当留痕: %q", logs)
	}
}

func TestProxyLoggerDropsUnrelatedHandshakeFailure(t *testing.T) {
	drainLogs()

	proxyLogger{}.Printf("[008] WARN: Cannot handshake client %v %v\n",
		"www.example.com", "tls: bad certificate")

	if logs := drainLogs(); logs != "" {
		t.Fatalf("无关主机的握手失败不该进运行日志: %q", logs)
	}
}

func TestProxyLoggerKeepsSignFailureAndDropsNoise(t *testing.T) {
	drainLogs()

	proxyLogger{}.Printf("[010] WARN: Cannot sign host certificate with provided CA: %v\n",
		"x509: invalid CA")
	if logs := drainLogs(); !strings.Contains(logs, "无法用当前 CA 签发站点证书") {
		t.Fatalf("CA 签发失败应当留痕: %q", logs)
	}

	proxyLogger{}.Printf("[011] WARN: Cannot read request from mitm'd client %v %v\n",
		"example.com", "unexpected EOF")
	if logs := drainLogs(); logs != "" {
		t.Fatalf("其余告警一律丢弃: %q", logs)
	}
}
