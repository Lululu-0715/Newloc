import XCTest

@testable import Newloc

/// 证书信任检测的**分类**逻辑。
///
/// 这两段分类是整条判据里唯一可能出错的地方：真实的检测要起一个临时 HTTPS
/// 服务再发一次请求，没法在单测里穷举；但「哪种结果归哪一档」可以，而且必须
/// 钉死 —— 分错一档，界面就会把「没测成」报成「需要你去修」，反过来也一样。
final class CertificateTrustProbeTests: XCTestCase {

    // MARK: - HTTP 结果分类

    func testHealthyBodyIsTrusted() {
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 200, body: "ok"), .trusted)
        // 服务端回的 body 带换行，判定前要 trim。
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 200, body: "ok\n"), .trusted)
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 200, body: "  ok  "), .trusted)
    }

    func testUnexpectedBodyIsUnavailable() {
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 200, body: "no"), .unavailable)
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 200, body: ""), .unavailable)
    }

    func testNonSuccessStatusIsUnavailable() {
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 500, body: "ok"), .unavailable)
        // 连接层都没谈起来时没有状态码，会走到 0。
        XCTAssertEqual(CertificateTrustProbe.classify(statusCode: 0, body: "ok"), .unavailable)
    }

    // MARK: - 错误分类

    func testCertificateErrorsAreUntrusted() {
        let codes = [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorClientCertificateRejected,
        ]

        for code in codes {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(CertificateTrustProbe.classify(error), .untrusted,
                           "错误码 \(code) 属于 TLS 层面被拒，应当判为「未信任」")
        }
    }

    func testNetworkErrorsAreUnavailableNotUntrusted() {
        let codes = [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost,
        ]

        for code in codes {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(CertificateTrustProbe.classify(error), .unavailable,
                           "错误码 \(code) 只是「没测成」，不能报成「未信任」"
                           + "——那会让用户去重装一张本来好端端的证书")
        }
    }

    /// 别的域的 NSError 即便凑巧用了同一个 code，也不该被当成 TLS 失败。
    func testForeignErrorDomainIsUnavailable() {
        let error = NSError(domain: "com.example.unrelated",
                            code: NSURLErrorServerCertificateUntrusted)
        XCTAssertEqual(CertificateTrustProbe.classify(error), .unavailable)
    }

    // MARK: - 三态文案

    func testVerdictsHaveDistinctText() {
        let texts = [
            CertificateTrustProbe.Verdict.trusted.text,
            CertificateTrustProbe.Verdict.untrusted.text,
            CertificateTrustProbe.Verdict.unavailable.text,
        ]
        XCTAssertEqual(Set(texts).count, 3, "三档必须能分辨，不能有两档文案相同")
    }
}

/// 连接诊断状态的失效逻辑。
@MainActor
final class ConnectionDiagnosticsTests: XCTestCase {

    func testInvalidateClearsBothLayers() {
        let diagnostics = ConnectionDiagnostics()

        diagnostics.invalidateTrust()
        diagnostics.invalidateLink()

        XCTAssertEqual(diagnostics.trust, .unavailable)
        XCTAssertEqual(diagnostics.link, .unknown)
    }

    /// 代理没在监听时，链路检测**不该发请求** —— 直接落 `unknown`。
    ///
    /// 这条守的是「关掉代理之后界面还在报『已连通』」那个撒谎状态：
    /// 证据必须跟着代理的生死走。
    ///
    /// 探针被指到一个不可能有人监听的端口，免得这条用例依赖
    /// 「测试机上恰好没有代理在跑」——单元测试跑在宿主 App 里，而宿主 App
    /// 自己就会把 8888 占上。
    func testLinkRefreshWithoutReachableProxyStaysUnknown() async {
        let probe = LinkProbe(config: LinkProbe.Config(host: "127.0.0.1", port: 1))
        let diagnostics = ConnectionDiagnostics(linkProbe: probe)

        await diagnostics.refreshLink()

        XCTAssertEqual(diagnostics.link, .unknown)
    }
}
