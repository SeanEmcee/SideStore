import Foundation

actor ControllerStub {
    var requests: [URLRequest] = []
    let versionStatus: Int
    let version: String
    let flushStatus: Int
    let wrongResponseURL: Bool
    let unavailable: Bool

    init(versionStatus: Int = 200, version: String = "sing-box 1.14.2", flushStatus: Int = 204,
         wrongResponseURL: Bool = false, unavailable: Bool = false) {
        self.versionStatus = versionStatus
        self.version = version
        self.flushStatus = flushStatus
        self.wrongResponseURL = wrongResponseURL
        self.unavailable = unavailable
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if unavailable { throw URLError(.timedOut) }
        let url = wrongResponseURL ? URL(string: "http://192.0.2.1/version")! : request.url!
        let isVersion = request.url!.path == "/version"
        let data = isVersion ? try JSONSerialization.data(withJSONObject: ["version": version]) : Data()
        return (data, HTTPURLResponse(url: url, statusCode: isVersion ? versionStatus : flushStatus,
                                      httpVersion: nil, headerFields: nil)!)
    }
}

@main
struct RecoveryTests {
    static let token = String(repeating: "a", count: 64) // Test fixture, never a deployed key.
    static let failure = "rppairing TCP connect failed: kind=ConnectionRefused, os_code=Some(61)"

    static func attempt(_ recovery: LocalVPNRecovery, token: String = RecoveryTests.token, cellular: Bool = true,
                        pairing: Bool = true, failure: String = RecoveryTests.failure) async throws -> Bool {
        try await recovery.attempt(token: token, isCellularVPN: cellular, isRemotePairing: pairing, failure: failure)
    }

    static func main() async throws {
        let stub = ControllerStub()
        let recovery = LocalVPNRecovery(request: { try await stub.send($0) })
        let succeeded = try await attempt(recovery)
        assert(succeeded)
        let repeated = try await attempt(recovery)
        assert(!repeated)
        let requests = await stub.requests
        assert(requests.count == 2)
        assert(requests.map(\.httpMethod) == ["GET", "POST"])
        assert(requests.map { $0.url!.path } == ["/version", "/cache/dns/flush"])
        for request in requests {
            assert(request.url!.host == "127.0.0.1" && request.url!.port == 51831)
            assert(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
            assert(request.timeoutInterval == 3)
        }
        for settings in [(false, true, token, failure), (true, false, token, failure),
                         (true, true, "", failure), (true, true, "malformed\nkey", failure),
                         (true, true, token, "InvalidPairing: certificate verification failed"),
                         (true, true, token, "NoDevice: remote endpoint is unavailable")] {
            let stub = ControllerStub()
            let skipped = try await attempt(LocalVPNRecovery(request: { try await stub.send($0) }),
                token: settings.2, cellular: settings.0, pairing: settings.1, failure: settings.3)
            assert(!skipped)
            let count = await stub.requests.count
            assert(count == 0)
        }
        for stub in [ControllerStub(versionStatus: 401), ControllerStub(versionStatus: 302),
                     ControllerStub(version: "Clash 1.0"), ControllerStub(wrongResponseURL: true),
                     ControllerStub(unavailable: true), ControllerStub(flushStatus: 500)] {
            let recovery = LocalVPNRecovery(request: { try await stub.send($0) })
            do { _ = try await attempt(recovery); assertionFailure("Expected controller failure") }
            catch { /* Expected; original transport failure remains authoritative. */ }
            let retried = try await attempt(recovery)
            assert(!retried)
            let requests = await stub.requests
            assert(requests.count <= 2)
            assert(requests.filter { $0.httpMethod == "POST" }.count <= 1)
        }
        let cancelledStub = ControllerStub()
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await attempt(LocalVPNRecovery(request: { try await cancelledStub.send($0) }))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Expected cancellation") } catch is CancellationError {} catch { throw error }
        let cancelledCount = await cancelledStub.requests.count
        assert(cancelledCount == 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let redirect = URLRequest(url: URL(string: "https://example.invalid")!)
        var result: URLRequest? = redirect
        LocalVPNRecovery.NoRedirects().urlSession(session, task: session.dataTask(with: redirect),
            willPerformHTTPRedirection: HTTPURLResponse(url: LocalVPNRecovery.controller, statusCode: 302,
                httpVersion: nil, headerFields: nil)!, newRequest: redirect) { result = $0 }
        assert(result == nil)
        print("Local VPN recovery: authenticated loopback requests, once-only transitions, Wi-Fi/credentials guards, rejection, timeout, cancellation, and redirect blocking passed.")
    }
}
