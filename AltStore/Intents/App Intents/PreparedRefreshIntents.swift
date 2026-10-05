import AppIntents

@available(iOS 17.0, *)
struct RefreshWithoutDataTogglesIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Apps Without Data Toggles"
    static var description = IntentDescription("Experimental background refresh that keeps cellular data on. Requires a local device endpoint reachable through your VPN while cellular is active. Does not open an app or run data shortcuts.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        debugLog("[PreparedRefresh] Refresh Apps Without Data Toggles invoked. Cellular data will not be changed.")
        let token = try await PreparedRefreshManager.shared.prepare()
        return .result(value: await PreparedRefreshManager.shared.install(token: token))
    }
}

@available(iOS 17.0, *)
struct PrepareAppRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Prepare App Refresh"
    static var description = IntentDescription("Download refresh profiles while online. Returns a single-use job valid for ten minutes. Does not install or open an app.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let token = try await PreparedRefreshManager.shared.prepare()
        return .result(value: token)
    }
}

@available(iOS 17.0, *)
struct InstallPreparedRefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "Install Prepared Refresh"
    static var description = IntentDescription("Install a prepared job through the local VPN without internet requests or opening an app. Returns success or failure so your next action can restore cellular data.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "Prepared Refresh") var job: String

    static var parameterSummary: some ParameterSummary { Summary("Install \(\.$job)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: await PreparedRefreshManager.shared.install(token: job))
    }
}
