package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/elazarl/goproxy"
)

// 本文件实现设备内的拦截代理。
//
// 设计约束（与「不占用系统 VPN」的产品定位一致）：
//   - 不使用 Network Extension，免费开发者账号也能跑；
//   - 只监听 127.0.0.1，覆盖范围由用户手动配置的 Wi-Fi HTTP 代理决定；
//   - 只对白名单域名做 TLS 中间人，其余流量一律透传，不做抓包；
//   - 除 WLOC 响应外不读取、不落盘任何请求内容。

const proxyListenPort = 8888

// caCommonName / caOrganization 是根证书的主题信息。
// 用户在「设置 → 通用 → 关于本机 → 证书信任设置」里看到的就是这两个字段，
// 换名字的时候只改这里即可，其他文件通过常量引用。
const (
	caCommonName   = "Newloc Root CA"
	caOrganization = "Newloc"
	leafCommonName = "Newloc Local Trust Probe"
)

// spoofState 保存当前生效的改写配置，由 Swift 侧通过 C 接口更新。
type spoofState struct {
	mu           sync.Mutex
	latitude     float64
	longitude    float64
	enabled      bool
	accuracy     int
	motionRadius int // 原地抖动半径（米）。0 表示关闭。
	verifyToken  string
	// caCertificate 是当前生效的根证书，供中间人动态签发叶子证书。
	caCertificate *tls.Certificate
}

var state = &spoofState{}

// ---------------------------------------------------------------------------
// 运行日志
// ---------------------------------------------------------------------------

const maxLogEntries = 200

var (
	logMu      sync.Mutex
	logEntries []string
)

// logEvent 记录一条带时间戳的运行日志，环形保留最近 200 条。
func logEvent(message string) {
	line := time.Now().Format("15:04:05.000") + "  " + message
	logMu.Lock()
	logEntries = append(logEntries, line)
	if len(logEntries) > maxLogEntries {
		logEntries = logEntries[len(logEntries)-maxLogEntries:]
	}
	logMu.Unlock()
}

// drainLogs 取出并清空积压日志，供 Swift 侧轮询拉取。
func drainLogs() string {
	logMu.Lock()
	defer logMu.Unlock()
	if len(logEntries) == 0 {
		return ""
	}
	out := strings.Join(logEntries, "\n")
	logEntries = nil
	return out
}

// ---------------------------------------------------------------------------
// 状态访问
// ---------------------------------------------------------------------------

func setSpoofConfig(lat, lon float64, enabled bool, accuracy int, motionRadius int) {
	state.mu.Lock()
	state.latitude = lat
	state.longitude = lon
	state.enabled = enabled
	state.accuracy = accuracy
	state.motionRadius = normalizeMotionRadius(motionRadius)
	state.mu.Unlock()
	logEvent(fmt.Sprintf("改写配置更新 enabled=%t accuracy=%d motionRadius=%d", enabled, accuracy, motionRadius))
}

func currentSpoofConfig() (lat, lon float64, enabled bool, accuracy int, motionRadius int) {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.latitude, state.longitude, state.enabled, state.accuracy, state.motionRadius
}

// motionRadiusSteps 是界面上允许选择的抖动半径（米）。
// 只认这三档，其余值一律归零，避免上层传进来一个离谱的半径把定位甩到几十公里外。
var motionRadiusSteps = []int{0, 5, 10, 20}

// normalizeMotionRadius 把任意输入收敛到受支持的档位。
func normalizeMotionRadius(radius int) int {
	for _, allowed := range motionRadiusSteps {
		if radius == allowed {
			return radius
		}
	}
	return 0
}

func setVerifyToken(token string) {
	state.mu.Lock()
	state.verifyToken = token
	state.mu.Unlock()
}

func matchesVerifyToken(token string) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.verifyToken != "" && state.verifyToken == token
}

func setCACertificate(cert *tls.Certificate) {
	state.mu.Lock()
	state.caCertificate = cert
	state.mu.Unlock()
}

func currentCACertificate() *tls.Certificate {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.caCertificate
}

// ---------------------------------------------------------------------------
// 域名白名单
// ---------------------------------------------------------------------------

// locationHosts 是允许做 TLS 中间人的主机集合。
//
// 前三个是 Apple 的全球 / 国内定位服务入口，中间一批（gsp / gspe）是
// 新版本系统把定位查询分散过去的备用入口——只拦前三台的话，iOS 26/27
// 上会出现「代理配好了但定位纹丝不动」的情况。最后两台是 Apple 地图
// 在国内使用的蓝点定位（高德）端点。
//
// 这里刻意逐条枚举而不用 *.apple.com 这类通配：通配会把 Apple ID、
// 推送、软件更新等大量无关流量也拉进中间人，既没必要也不安全。
var locationHosts = []string{
	"gs-loc.apple.com",
	"gs-loc-cn.apple.com",
	"gsp-ssl.ls.apple.com",
	"gsp10-ssl.ls.apple.com",
	"gsp10-ssl.apple.com",
	"gsp64-ssl.ls.apple.com",
	"gspe1-ssl.ls.apple.com",
	"gspe19-ssl.ls.apple.com",
	"gspe19-2-ssl.ls.apple.com",
	"gspe35-ssl.ls.apple.com",
	"gspe79-ssl.ls.apple.com",
	"gspe85-ssl.ls.apple.com",
	"bluedot.is.autonavi.com",
	"bluedot.is.autonavi.com.gds.alibabadns.com",
}

// locationHostSet 是 locationHosts 的查表版本。
var locationHostSet = func() map[string]bool {
	set := make(map[string]bool, len(locationHosts))
	for _, host := range locationHosts {
		set[host] = true
	}
	return set
}()

// isLocationHost 判断主机名是否属于需要改写的定位服务。
func isLocationHost(host string) bool {
	return locationHostSet[normalizeHost(host)]
}

// normalizeHost 去掉端口、统一小写、去掉尾部点号。
func normalizeHost(host string) string {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if strings.Contains(host, ":") {
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
	}
	return host
}

// locationHostPattern 匹配「疑似 Apple 定位端点」的主机名形态。
//
// 白名单是静态枚举的，但 Apple 的定位服务会在一大批带编号的主机之间轮换
// （gsp13-ssl、gsp27-ssl、gspe42-ssl……），永远枚举不完。没被拦下的那一台
// 会原样透传，系统拿到的就是**真实坐标**——表现正是「用着用着跳回真实位置」。
//
// 这里**不做拦截**（拦截要靠白名单，否则会把无关流量拉进中间人），
// 只在 spoofing 开启时把这情况记进运行日志，让用户在「运行日志与诊断」里
// 一眼看出是不是这个原因，而不是对着「定位不生效」干猜。
var locationHostPattern = regexp.MustCompile(`^(gspe?|gs-loc)[0-9-]*(-ssl)?(\.ls)?\.apple\.com$`)

// looksLikeLocationHost 判断主机名像不像定位端点但不在白名单里。
func looksLikeLocationHost(host string) bool {
	host = normalizeHost(host)
	if isLocationHost(host) {
		return false
	}
	return locationHostPattern.MatchString(host)
}

// isProxyProbeHost 判断是否是「代理连通性验证」用的主机。
func isProxyProbeHost(host string) bool {
	host = normalizeHost(host)
	return host == "baidu.com" || host == "www.baidu.com" || strings.HasSuffix(host, ".baidu.com")
}

// metersPerDegreeLatitude 是纬度方向 1 度对应的米数（地球平均半径估算）。
const metersPerDegreeLatitude = 111320.0

// driftCoordinates 在以 (lat, lon) 为圆心、radiusMeters 为半径的圆内
// 随机取一个点。radiusMeters <= 0 时原样返回。
//
// 半径按 sqrt(u) 分布取样而不是均匀取样，这样点在圆面积上是均匀分布的，
// 否则会明显往圆心堆。经度方向要除以纬度的余弦做修正，越靠近两极
// 同样的米数对应的经度差越大。
func driftCoordinates(lat, lon float64, radiusMeters int) (float64, float64) {
	if radiusMeters <= 0 {
		return lat, lon
	}

	radius := math.Sqrt(rand.Float64()) * float64(radiusMeters)
	angle := rand.Float64() * 2 * math.Pi

	deltaLat := (radius * math.Cos(angle)) / metersPerDegreeLatitude

	// 极点附近 cos(lat) 趋近 0，经度差会发散，此时只做纬度方向的抖动。
	cosLat := math.Cos(lat * math.Pi / 180)
	if math.Abs(cosLat) < 1e-6 {
		return lat + deltaLat, lon
	}
	deltaLon := (radius * math.Sin(angle)) / (metersPerDegreeLatitude * cosLat)

	return lat + deltaLat, lon + deltaLon
}

// ---------------------------------------------------------------------------
// 代理构建
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 代理内部日志
// ---------------------------------------------------------------------------

// 这几条是 goproxy 内部 `ctx.Warnf` 的原文片段，挑出来是因为它们各自对应
// 一个用户在界面上**完全看不见**的失败：
const (
	handshakeFailureMarker = "Cannot handshake client"
	signFailureMarker      = "Cannot sign host certificate"
	dialFailureMarker      = "Error dialing to "
)

// proxyLogger 把 goproxy 内部的告警接进本工程的运行日志。
//
// ## 为什么必须接
//
// 客户端**拒绝本机动态签发的证书**时，goproxy 走到
//
//	ctx.Warnf("Cannot handshake client %v %v", r.Host, err)
//
// 而这条告警默认只写到 `os.Stderr` —— 在 iOS 上等于扔进黑洞。于是「系统不信任
// 我们的证书」这件事在诊断页里**完全不可见**：开关亮着、坐标写好了、校验却永远
// 不生效，用户和排查的人都拿不到任何线索。这是本文件原先最大的诊断盲区。
//
// ## 为什么只留三条
//
//   - 全局代理模式下这台代理会经手大量无关流量，那条握手失败告警对**无关主机**
//     是常态（用户没在系统里装过本机证书的其它 App 都算）。逐条记录既产生噪声，
//     也会泄露用户的浏览目标 —— 取舍与 `isProxyProbeHost` 那一段一致。
//   - `logEntries` 只有 200 条环形缓冲，被无关告警刷掉，真正的问题就查不到了。
type proxyLogger struct{}

func (proxyLogger) Printf(format string, args ...any) {
	message := fmt.Sprintf(format, args...)

	switch {
	case strings.Contains(message, handshakeFailureMarker):
		host := proxyLogField(message, handshakeFailureMarker)
		if !isLocationHost(host) && !isProxyProbeHost(host) && !looksLikeLocationHost(host) {
			return
		}
		logEvent("⚠ TLS 握手失败（系统可能拒绝了本机证书）: " + host +
			" —— " + proxyLogDetail(message))

	case strings.Contains(message, signFailureMarker):
		logEvent("⚠ 无法用当前 CA 签发站点证书 —— " + proxyLogDetail(message))

	case strings.Contains(message, dialFailureMarker):
		host := proxyLogField(message, dialFailureMarker)
		if !isLocationHost(host) && !isProxyProbeHost(host) && !looksLikeLocationHost(host) {
			return
		}
		logEvent("⚠ 上游连接失败: " + host + " —— " + proxyLogDetail(message))
	}

	// 其余一律丢弃，也不写 stderr。
}

// proxyLogField 取 `marker` 之后的第一个空白分隔字段 —— 日志里的主机名就在那儿。
func proxyLogField(message, marker string) string {
	index := strings.Index(message, marker)
	if index < 0 {
		return ""
	}
	rest := strings.TrimLeft(message[index+len(marker):], " ")
	if end := strings.IndexAny(rest, " \t\n\r"); end >= 0 {
		return rest[:end]
	}
	return rest
}

// proxyLogDetail 去掉 goproxy 前缀里对本工程没有意义的会话号（"[003] WARN: "），
// 压平换行并限长，避免一条告警把 200 条缓冲吃掉一大块。
func proxyLogDetail(message string) string {
	message = strings.TrimSpace(message)
	if strings.HasPrefix(message, "[") {
		if close := strings.Index(message, "] "); close > 0 && close <= 5 {
			message = message[close+2:]
		}
	}
	message = strings.TrimPrefix(message, "WARN: ")
	message = strings.TrimPrefix(message, "INFO: ")
	message = strings.Join(strings.Fields(message), " ")

	runes := []rune(message)
	if len(runes) > 200 {
		return string(runes[:200]) + "…"
	}
	return message
}

// newProxyServer 组装 goproxy 实例。
func newProxyServer(caCert *tls.Certificate) *goproxy.ProxyHttpServer {
	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false
	// 默认的 Logger 写 os.Stderr，在 iOS 上什么也留不下。换成接进运行日志的
	// 那一个 —— 否则「系统拒绝了我们的证书」永远是黑箱，见 proxyLogger。
	proxy.Logger = proxyLogger{}

	proxy.NonproxyHandler = http.HandlerFunc(handleDirectVisit)

	if caCert != nil {
		mitmAction := &goproxy.ConnectAction{
			Action:    goproxy.ConnectMitm,
			TLSConfig: goproxy.TLSConfigFromCA(caCert),
		}
		proxy.OnRequest().HandleConnectFunc(func(host string, ctx *goproxy.ProxyCtx) (*goproxy.ConnectAction, string) {
			if isLocationHost(host) {
				logEvent("CONNECT " + host + " → 中间人")
				return mitmAction, host
			}
			if isProxyProbeHost(host) {
				logEvent("CONNECT " + host + " → 中间人（代理验证）")
				return mitmAction, host
			}
			// 疑似定位端点却没进白名单：会把真实坐标放过去，必须留痕。
			if looksLikeLocationHost(host) {
				if _, _, enabled, _, _ := currentSpoofConfig(); enabled {
					logEvent("⚠ 疑似定位端点未在白名单，已透传（可能拿到真实位置）: " + host)
				}
			}
			// 全局代理模式下会有大量无关 HTTPS 流量经过这里。
			// 逐条记录既产生噪声又可能泄露浏览目标，因此只记录定位与验证流量。
			return goproxy.OkConnect, host
		})
	}

	proxy.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		return serveInterceptedRequest(req, ctx)
	})
	proxy.OnResponse().DoFunc(rewriteLocationResponse)
	return proxy
}

// handleDirectVisit 处理「用 Safari 直接访问 127.0.0.1:8888」这类非代理请求。
func handleDirectVisit(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/cert":
		serveCACertificateDownload(w)

	case "/":
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8">` +
			`<meta http-equiv="refresh" content="0;url=/cert"><title>CA Certificate</title></head>` +
			`<body><p><a href="/cert">下载 CA 证书</a></p></body></html>`))

	case "/coords":
		lat, lon, enabled, accuracy, motionRadius := currentSpoofConfig()
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		fmt.Fprintf(w, `{"enabled":%t,"lat":%.6f,"lon":%.6f,"accuracy":%d,"motionDriftRadius":%d}`,
			enabled, lat, lon, accuracy, motionRadius)

	case "/proxy.mobileconfig", "/proxy.mobileconfig/":
		w.Header().Set("Content-Type", "application/x-apple-aspen-config")
		w.Header().Set("Content-Disposition", "attachment; filename=Newloc-Proxy.mobileconfig")
		_, _ = w.Write([]byte(buildProxyMobileConfig()))

	default:
		// 兼容 rendoor.cert 这类自定义主机名，用于一步弹出证书安装。
		if normalizeHost(r.Host) == "rendoor.cert" {
			if r.URL.Path == "/cert" {
				serveCACertificateDownload(w)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><head><meta charset="utf-8">` +
				`<meta http-equiv="refresh" content="2;url=/cert"><title>Preparing Certificate</title></head>` +
				`<body><p>正在准备 CA 证书，如未自动跳转请点击 <a href="/cert">这里</a>。</p></body></html>`))
			return
		}
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("这是一个定位拦截代理。请用 Safari 访问 " +
			"http://127.0.0.1:8888/proxy.mobileconfig 配置代理，或访问 http://127.0.0.1:8888/cert 安装证书。"))
	}
}

// serveCACertificateDownload 输出根证书，供 iOS 安装描述文件使用。
func serveCACertificateDownload(w http.ResponseWriter) {
	caCert := currentCACertificate()
	if caCert == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("CA 证书尚未生成"))
		return
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCert.Certificate[0]})
	w.Header().Set("Content-Type", "application/x-x509-ca-cert")
	w.Header().Set("Content-Disposition", "attachment; filename=Newloc-CA.crt")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(certPEM)
}

// readableBody 把「已经读出来的前缀 + 尚未读的剩余流」拼成一个 Response.Body。
//
// 用 io.NopCloser(io.MultiReader(...)) 是不行的：NopCloser 的 Close 是空操作，
// MultiReader 又不持有 Close，于是底层 resp.Body 永远不会被关闭——
// HTTP 连接因此既不能复用也不会及时回收，长时间运行后表现为连接堆积。
// 这里显式把 Close 转发给原始 body。
func readableBody(consumed []byte, rest io.ReadCloser) io.ReadCloser {
	return struct {
		io.Reader
		io.Closer
	}{
		Reader: io.MultiReader(bytes.NewReader(consumed), rest),
		Closer: rest,
	}
}

// serveInterceptedRequest 在请求阶段处理本地伪造的响应。
func serveInterceptedRequest(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	host := normalizeHost(req.Host)

	// 代理链路验证：把 https://www.baidu.com/paopao-verify-<token> 拦下来，
	// 回显 token。App 侧用它确认 Wi-Fi 代理是否真的走到了本机。
	if isProxyProbeHost(host) && strings.HasPrefix(req.URL.Path, "/location-verify-") {
		token := strings.TrimPrefix(req.URL.Path, "/location-verify-")
		logEvent("收到代理验证请求")
		if matchesVerifyToken(token) {
			resp := goproxy.NewResponse(req, "text/plain", http.StatusOK, token)
			resp.Header.Set("Cache-Control", "no-store")
			return req, resp
		}
	}

	if host != "rendoor.cert" && host != "www.rendoor.cert" {
		return req, nil
	}

	caCert := currentCACertificate()
	if caCert == nil {
		return req, nil
	}

	if req.URL.Path == "/cert" {
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCert.Certificate[0]})
		resp := goproxy.NewResponse(req, "application/x-x509-ca-cert", http.StatusOK, string(certPEM))
		resp.Header.Set("Content-Disposition", `attachment; filename=Newloc-CA.crt`)
		resp.Header.Set("Cache-Control", "no-store")
		return req, resp
	}

	html := `<!DOCTYPE html><html><head><meta charset="utf-8">` +
		`<meta http-equiv="refresh" content="2;url=/cert"><title>Preparing Certificate</title></head>` +
		`<body><p>正在准备 CA 证书，如未自动跳转请点击 <a href="/cert">这里</a>。</p></body></html>`
	return req, goproxy.NewResponse(req, "text/html; charset=utf-8", http.StatusOK, html)
}

// rewriteLocationResponse 在响应阶段改写 WLOC 坐标。
func rewriteLocationResponse(resp *http.Response, ctx *goproxy.ProxyCtx) *http.Response {
	if resp == nil || resp.Request == nil {
		return resp
	}
	if !isLocationHost(resp.Request.Host) ||
		resp.Request.URL.Path != "/clls/wloc" ||
		resp.Request.Method != http.MethodPost {
		return resp
	}

	lat, lon, enabled, accuracy, motionRadius := currentSpoofConfig()

	if resp.ContentLength > maxPatchBodyBytes {
		logEvent(fmt.Sprintf("WLOC 响应过大，跳过改写（%d 字节）", resp.ContentLength))
		return resp
	}

	originalBody := resp.Body
	body, err := io.ReadAll(io.LimitReader(originalBody, maxPatchBodyBytes+1))
	if err != nil {
		logEvent("读取 WLOC 响应失败: " + err.Error())
		resp.Body = readableBody(body, originalBody)
		return resp
	}
	if int64(len(body)) > maxPatchBodyBytes {
		logEvent("WLOC 响应过大，跳过改写")
		resp.Body = readableBody(body, originalBody)
		return resp
	}
	_ = originalBody.Close()

	// 未开启虚拟定位、或响应非 200／为空时原样放行。
	if !enabled || resp.StatusCode != http.StatusOK || len(body) == 0 {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp
	}

	// 开启抖动后，每次改写都在半径内随机偏移一次。
	// 系统看到的是「同一个位置附近的微小漂移」，这正是真实 GPS 的表现；
	// 死钉在一个坐标上反而容易被判定为伪造。
	driftLat, driftLon := driftCoordinates(lat, lon, motionRadius)

	patched, stats, err := rewriteResponseBody(body, wlocTarget{
		Latitude:      driftLat,
		Longitude:     driftLon,
		Accuracy:      accuracy,
		MotionEnabled: motionRadius > 0,
	})
	if err != nil || bytes.Equal(patched, body) {
		if err != nil {
			logEvent("WLOC 改写跳过: " + err.Error())
		}
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp
	}

	resp.Body = io.NopCloser(bytes.NewReader(patched))
	resp.ContentLength = int64(len(patched))
	// 改写后长度变了，必须清掉与长度相关和编码相关的头，只保留 Content-Length。
	resp.Header.Del("Content-Encoding")
	resp.Header.Del("Transfer-Encoding")
	resp.Header.Set("Content-Length", strconv.Itoa(len(patched)))
	logEvent(fmt.Sprintf("WLOC 已改写 位置=%d WiFi=%d 基站=%d 跳过=%d 输入=%d 输出=%d",
		stats.Locations, stats.WiFiDevices, stats.CellSections, stats.Skipped, len(body), len(patched)))
	return resp
}

// ---------------------------------------------------------------------------
// 描述文件与代理生命周期
// ---------------------------------------------------------------------------

// buildProxyMobileConfig 生成一份全局 HTTP 代理描述文件。
//
// 注意：iOS 要求配置描述文件经过 MDM 签名才能安装，自签场景下这个文件主要
// 用作模板，实际仍引导用户在 Wi-Fi 设置里手动填写代理。
func buildProxyMobileConfig() string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadDescription</key>
			<string>为 Newloc 配置本机 HTTP 代理。</string>
			<key>PayloadDisplayName</key>
			<string>Newloc Local Proxy</string>
			<key>PayloadIdentifier</key>
			<string>` + bundlePrefix + `.proxy.payload</string>
			<key>PayloadType</key>
			<string>com.apple.proxy.http.global</string>
			<key>PayloadUUID</key>
			<string>` + randomUUID() + `</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>GlobalHTTPProxy</key>
			<dict>
				<key>ProxyServer</key>
				<string>127.0.0.1</string>
				<key>ProxyServerPort</key>
				<integer>` + strconv.Itoa(proxyListenPort) + `</integer>
				<key>ProxyType</key>
				<string>Manual</string>
			</dict>
		</dict>
	</array>
	<key>PayloadDisplayName</key>
	<string>Newloc Local Proxy</string>
	<key>PayloadIdentifier</key>
	<string>` + bundlePrefix + `.proxy</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>` + randomUUID() + `</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>`
}

// randomUUID 生成一个 v4 UUID 字符串。
func randomUUID() string {
	u := randomHex32()
	if len(u) < 32 {
		return u
	}
	return fmt.Sprintf("%s-%s-%s-%s-%s", u[0:8], u[8:12], u[12:16], u[16:20], u[20:32])
}

// startProxy 启动代理服务，返回可传给 stopProxy 的句柄。
func startProxy(certPEM, keyPEM []byte, lat, lon float64, enabled bool, accuracy int, motionRadius int) (*http.Server, error) {
	caCert, err := parseCA(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}

	setCACertificate(caCert)
	setSpoofConfig(lat, lon, enabled, accuracy, motionRadius)

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", proxyListenPort))
	if err != nil {
		return nil, err
	}

	server := &http.Server{Handler: newProxyServer(caCert)}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logEvent("代理服务异常: " + err.Error())
		}
	}()
	logEvent(fmt.Sprintf("代理已启动 127.0.0.1:%d", proxyListenPort))
	return server, nil
}

// isProxyListening 实际探一次代理端口是否还在监听。
//
// 为什么需要它：进程被 iOS 挂起时，Go 侧的监听 socket 会失效，但 Go 进程
// 并没有退出，Swift 侧自维护的 status 也就不会变成 .stopped。上层若只信
// status，就会把「代理其实已经死了」当成「代理在跑」，于是环境检测里
// Wi-Fi 代理链路被误判成「跳过」——用户看到的就是「Wi-Fi 设置是对的，
// 但怎么都没用」。
//
// 直接 dial 127.0.0.1:8888 是最可靠的判断：端口还接得上就说明监听还在。
func isProxyListening() bool {
	conn, err := net.DialTimeout(
		"tcp",
		fmt.Sprintf("127.0.0.1:%d", proxyListenPort),
		500*time.Millisecond,
	)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// stopProxy 优雅关闭代理。
func stopProxy(server *http.Server) error {
	if server == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := server.Shutdown(ctx)
	setCACertificate(nil)
	return err
}
