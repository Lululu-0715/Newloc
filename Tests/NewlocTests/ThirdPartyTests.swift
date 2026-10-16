import XCTest
@testable import Newloc

/// 第三方客户端模式：客户端映射、导入地址与控制器状态机（URLProtocol 桩）。
@MainActor
final class ThirdPartyTests: XCTestCase {

    // MARK: - 客户端映射

    func testImportURLContainsRepoAndModuleFile() {
        for client in ThirdPartyClient.allCases {
            let url = client.importURL.absoluteString
            XCTAssertTrue(url.hasPrefix("https://cdn.jsdelivr.net/gh/"),
                          "\(client.rawValue) 应走 jsDelivr")
            XCTAssertTrue(url.contains(ThirdPartyConfig.githubRepo),
                          "\(client.rawValue) 应包含仓库地址")
            XCTAssertTrue(url.hasSuffix("/modules/\(client.moduleFile)"),
                          "\(client.rawValue) 模块文件映射错误")
        }
    }

    func testSurgeAndEgernShareSgmodule() {
        XCTAssertEqual(ThirdPartyClient.surge.moduleFile,
                       ThirdPartyClient.egern.moduleFile)
        XCTAssertEqual(ThirdPartyClient.surge.moduleFile, "wloc.sgmodule")
    }

    func testSixClientsWithUniqueSchemes() {
        XCTAssertEqual(ThirdPartyClient.allCases.count, 6)
        let schemes = ThirdPartyClient.allCases.compactMap(\.openScheme)
        XCTAssertEqual(Set(schemes).count, 6)
    }

    // MARK: - 控制器状态机

    func testQueryWithoutSavedCoordinateMapsToModuleIdle() async {
        let controller = makeController { request in
            Self.respondJSON(#"{"success":false,"error":"无已保存的坐标","diag":{"lastRun":1}}"#)
        }
        await controller.probe()
        XCTAssertEqual(controller.state, .moduleIdle)
        XCTAssertNotNil(controller.lastDiag, "诊断回显应透传给界面")
    }

    func testSaveSuccessActivates() async {
        let controller = makeController { request in
            Self.respondJSON(#"{"success":true,"longitude":113.0,"latitude":22.0,"accuracy":25,"driftRadius":0}"#)
        }
        let ok = await controller.activate(latitude: 22.0, longitude: 113.0)
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .active)
    }

    func testClearReturnsToModuleIdle() async {
        let controller = makeController { request in
            if let url = request.url?.absoluteString, url.contains("action=clear") {
                return Self.respondJSON(#"{"success":true}"#)
            }
            return Self.respondJSON(#"{"success":true,"longitude":113.0,"latitude":22.0}"#)
        }
        _ = await controller.activate(latitude: 22.0, longitude: 113.0)
        XCTAssertEqual(controller.state, .active)

        let ok = await controller.deactivate()
        XCTAssertTrue(ok)
        XCTAssertEqual(controller.state, .moduleIdle)
    }

    func testNonJSONResponseMeansUnreachable() async {
        // 模块没装时，请求穿过客户端拿到的是 Apple 真实应答（非我们的 JSON）。
        let controller = makeController { request in
            Self.respondRaw("<html>Apple</html>", status: 404)
        }
        await controller.probe()
        XCTAssertEqual(controller.state, .unreachable)
        XCTAssertFalse(controller.isActive)
    }

    func testNetworkFailureMeansUnreachable() async {
        // 客户端没开连接 → 请求直接失败。
        let controller = makeController { request in
            throw URLError(.notConnectedToInternet)
        }
        await controller.probe()
        XCTAssertEqual(controller.state, .unreachable)
        XCTAssertNotNil(controller.lastError)
    }

    func testActivateFailureCarriesModuleError() async {
        let controller = makeController { request in
            Self.respondJSON(#"{"success":false,"error":"无法写入客户端存储"}"#)
        }
        let ok = await controller.activate(latitude: 22.0, longitude: 113.0)
        XCTAssertFalse(ok)
        XCTAssertEqual(controller.state, .unreachable)
        XCTAssertEqual(controller.lastError, "无法写入客户端存储")
    }

    // MARK: - 桩件

    private func makeController(
        _ handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> ThirdPartyController {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ThirdPartyController(session: URLSession(configuration: config))
    }

    private static func respondJSON(_ body: String) -> (Int, Data) {
        (200, Data(body.utf8))
    }

    private static func respondRaw(_ body: String, status: Int) -> (Int, Data) {
        (status, Data(body.utf8))
    }
}

/// 按 handler 应答的 URLProtocol 桩：不真实发网络请求。
/// URLProtocol 实例由会话机制创建，不是我们 new 的那个，
/// 所以 handler 放静态 —— 每个测试用例写入，互不串扰。
private final class StubURLProtocol: URLProtocol {

    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!,
                                           statusCode: status,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
