import Foundation

/// One instance per prepared refresh. Never controls the cellular radio.
actor LocalVPNRecovery {
    static let controller = URL(string: "http://127.0.0.1:51831")!
    typealias Request = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var attempted = false
    private let request: Request

    init(request: @escaping Request = LocalVPNRecovery.send) {
        self.request = request
    }

    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func eligible(isCellularVPN: Bool, isRemotePairing: Bool, failure: String) -> Bool {
        // Only a measured TCP transport failure, never pairing credentials or TLS authentication.
        isCellularVPN && isRemotePairing && failure.contains("TCP connect failed:") &&
        ["os_code=Some(61)", "os_code=Some(54)", "os_code=Some(65)"].contains(where: failure.contains)
    }

    func attempt(token: String, isCellularVPN: Bool, isRemotePairing: Bool, failure: String) async throws -> Bool {
        guard !attempted, Self.validToken(token),
              Self.eligible(isCellularVPN: isCellularVPN, isRemotePairing: isRemotePairing, failure: failure) else { return false }
        attempted = true // Includes rejected/ambiguous responses: never repeat a network transition.
        try Task.checkCancellation()
        let versionURL = Self.controller.appendingPathComponent("version")
        let (data, response) = try await request(Self.makeRequest(versionURL, method: "GET", token: token))
        guard response.url == versionURL, response.statusCode == 200, data.count <= 4096,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String, version.hasPrefix("sing-box ") else {
            throw RecoveryError.controllerRejected
        }
        try Task.checkCancellation()
        let flushURL = Self.controller.appendingPathComponent("cache/dns/flush")
        let (_, flushResponse) = try await request(Self.makeRequest(flushURL, method: "POST", token: token))
        guard flushResponse.url == flushURL, flushResponse.statusCode == 204 else {
            throw RecoveryError.controllerRejected
        }
        // Needs phone testing: 204 acknowledges the API, not a usable device connection.
        return true
    }

    private static func makeRequest(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RecoveryError.controllerRejected }
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not propagate response bodies, URLs or request headers into refresh logs.
            throw RecoveryError.controllerUnavailable
        }
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    enum RecoveryError: LocalizedError {
        case controllerRejected, controllerUnavailable
        var errorDescription: String? {
            switch self {
            case .controllerRejected: return "The local VPN recovery controller rejected the request. Check the selected VPN profile and saved recovery key."
            case .controllerUnavailable: return "The local VPN recovery controller is unavailable or timed out. Check that the recovery VPN profile is running."
            }
        }
    }
}
