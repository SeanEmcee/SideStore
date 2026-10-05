import Foundation
import CoreData
import SideSign
import Minimuxer

/// Neither phase changes cellular data or opens SideStore or Shortcuts.
/// A caller may choose a two-phase data-toggle workaround if its VPN requires it.
actor PreparedRefreshManager {
    static let shared = PreparedRefreshManager()
    private var isRunning = false

    private var store: PreparedRefreshJobStore {
        PreparedRefreshJobStore(directory: FileManager.default.applicationSupportDirectory.appendingPathComponent("PreparedRefresh", isDirectory: true))
    }

    func prepare() async throws -> String {
        guard !isRunning, !AppManager.shared.isActivelyManagingAnyApp else { throw PreparedRefreshError.busy }
        isRunning = true
        defer { isRunning = false }
        return try await CellularRefreshManager.$isExternallyManaged.withValue(true) {
            try await self.prepareProfiles()
        }
    }

    private func prepareProfiles() async throws -> String {
        try await DatabaseManager.shared.start()
        let db = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let team = try await AuthManager.shared.getAuthenticatedTeam()
        let apps = await db.perform { InstalledApp.fetchAppsForRefreshingAll(in: db) }
        guard !apps.isEmpty else { throw OperationError.noInstalledApps }
        let shared = SharedPipelineContext()
        var entries: [PreparedRefreshJob.App] = []
        for app in apps {
            try Task.checkCancellation()
            let context = await db.perform {
                let context = InstallAppOperationContext(
                    pipelineSteps: PipelineStepDefinition.refresh,
                    bundleIdentifier: app.bundleIdentifier,
                    dbBackgroundContext: db, sharedContext: shared,
                    handler: PipelineHandler(),
                    activeSigningCertificate: CertificateManager.shared.activeCertificate?.certificate)
                context.installedApp = app
                context.customBundleIdentifier = app.customBundleIdentifier
                context.useMainProfile = app.useMainProfile
                context.targetAppBundle = ALTApplication(fileURL: app.fileURL)
                return context
            }
            guard context.targetAppBundle != nil else {
                throw PreparedRefreshError.configuration("An installed app is not cached. Refresh it normally on Wi-Fi once before using prepared refresh.")
            }
            AppManager.shared.set(Progress(totalUnitCount: 100), for: .refresh(app))
            defer { AppManager.shared.set(nil, for: .refresh(app)) }
            // Reuse upstream's certificate selection, verification and Apple profile requests.
            // No re-signing, certificate revocation, device registration, or installation here.
            try await UpdateAppCertificateOperation(context: context).execute()
            try await VerifyCertificateOperation(context: context, willResign: false).execute()
            let profiles = try await FetchProvisioningProfilesOperation(context: context).execute()
            let snapshot = await db.perform { (app.bundleIdentifier, app.resignedBundleIdentifier, app.certificateSerialNumber ?? "") }
            guard let main = profiles[snapshot.0], main.bundleIdentifier == snapshot.1,
                  !snapshot.2.isEmpty else {
                throw PreparedRefreshError.configuration("The installed app identity changed or its certificate is unavailable. Refresh it normally first.")
            }
            for profile in profiles.values {
                guard profile.teamIdentifier == team.identifier, profile.expirationDate > Date(),
                      profile.certificates.contains(where: { $0.serialNumber == snapshot.2 }) else {
                    throw PreparedRefreshError.configuration("A downloaded profile does not match the installed signing certificate and account.")
                }
            }
            entries.append(.init(bundleIdentifier: snapshot.0, resignedBundleIdentifier: snapshot.1,
                                 certificateSerial: snapshot.2, profiles: profiles.mapValues(\.data)))
        }
        let token = try store.save(.init(version: 1, createdAt: Date(), teamIdentifier: team.identifier, apps: entries))
        debugLog("[PreparedRefresh] Prepared profiles for \(entries.count) app(s). No device installation performed.")
        return token
    }

    /// Always return a status for recoverable errors, so Shortcuts reaches Set Cellular Data On.
    func install(token: String) async -> String {
        guard !isRunning, !AppManager.shared.isActivelyManagingAnyApp else {
            return "Refresh failed: another app operation is running."
        }
        isRunning = true
        defer { isRunning = false }
        var completed = 0
        do {
            let job = try store.claim(token)
            try await DatabaseManager.shared.start()
            let db = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let team = try await AuthManager.shared.getAuthenticatedTeam() // reads saved team; no internet request
            guard team.identifier == job.teamIdentifier else { throw PreparedRefreshError.invalidJob }
            guard let pairing = PairingFileManager.shared.fetchPairingFile() else {
                throw PreparedRefreshError.configuration("No configured pairing file is available.")
            }
            syncMinimuxerBackendFromUserDefaults()
            try await minimuxerStart(pairing, preferred: PairingFileManager.shared.preferredProtocol)
            // Needs proper testing on a locked iPhone: bypass Wi-Fi policy, never device readiness.
            let deadline = Date().addingTimeInterval(5)
            var ready = false
            while Date() < deadline {
                try Task.checkCancellation()
                await minimuxer.network.refreshEndpoint()
                if case .success(true) = await minimuxer.core.isReady(withNetworkCheck: false) { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready else { throw PreparedRefreshError.configuration("The local device endpoint did not become ready. Check sing-box and the SideStore connection configuration.") }
            let liveUDID = try await fetchUDID(forceLive: true)
            for entry in job.apps {
                try Task.checkCancellation()
                let app = try await db.perform { () throws -> InstalledApp in
                    guard let app = InstalledApp.first(satisfying: NSPredicate(format: "bundleIdentifier == %@", entry.bundleIdentifier), in: db),
                          app.isActive, app.resignedBundleIdentifier == entry.resignedBundleIdentifier,
                          app.certificateSerialNumber == entry.certificateSerial else {
                        throw PreparedRefreshError.invalidJob
                    }
                    return app
                }
                AppManager.shared.set(Progress(totalUnitCount: 100), for: .refresh(app))
                defer { AppManager.shared.set(nil, for: .refresh(app)) }
                let profiles = try entry.profiles.mapValues { try ALTProvisioningProfile(data: $0) }
                guard let main = profiles[entry.bundleIdentifier], main.bundleIdentifier == entry.resignedBundleIdentifier else {
                    throw PreparedRefreshError.invalidJob
                }
                // Validate every app/extension before sending any profile for this app.
                for profile in profiles.values {
                    guard profile.teamIdentifier == job.teamIdentifier, profile.expirationDate > Date(),
                          profile.deviceIDs.contains(liveUDID),
                          profile.certificates.contains(where: { $0.serialNumber == entry.certificateSerial }) else {
                        throw PreparedRefreshError.invalidJob
                    }
                }
                for profile in profiles.values {
                    try Task.checkCancellation()
                    try await minimuxer.core.installProvisioningProfile(profile: profile.data)
                }
                try await verifyInstalledProfiles(Array(profiles.values))
                // Advance expiry only after the device returns the newly installed profile UUIDs.
                try await db.perform {
                    app.update(provisioningProfile: main)
                    for ext in app.appExtensions {
                        if let profile = profiles[ext.bundleIdentifier] { ext.update(provisioningProfile: profile) }
                    }
                    try db.save()
                }
                completed += 1
            }
            await recordAttempt(db: db, error: nil)
            return "Refreshed \(completed) app(s). Installed profiles verified through the local device connection."
        } catch {
            let db = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            await recordAttempt(db: db, error: error)
            debugLog("[PreparedRefresh] Installation failed after \(completed) app(s): \(error.localizedDescription)")
            return "Refresh failed after \(completed) app(s): \(error.localizedDescription). Prepare a new refresh to retry."
        }
    }

    private func verifyInstalledProfiles(_ expected: [ALTProvisioningProfile]) async throws {
        let directory = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("RefreshVerification-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: directory) }
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        let path = try await minimuxer.core.dumpProfiles(docsPath: directory.path, mode: .raw)
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
        let installed = files.filter { $0.pathExtension == "mobileprovision" }.compactMap { file in
            try? ALTProvisioningProfile(data: Data(contentsOf: file))
        }
        for profile in expected {
            guard installed.contains(where: {
                $0.uuid == profile.uuid && $0.bundleIdentifier == profile.bundleIdentifier &&
                $0.teamIdentifier == profile.teamIdentifier && $0.expirationDate == profile.expirationDate
            }) else {
                throw PreparedRefreshError.configuration("The device did not return a newly installed profile. Expiry was not advanced.")
            }
        }
    }

    private func recordAttempt(db: NSManagedObjectContext, error: Error?) async {
        await db.perform {
            let result: Result<[String: Result<InstalledApp, Error>], Error> = error.map { .failure($0) } ?? .success([:])
            _ = RefreshAttempt(identifier: UUID().uuidString, result: result, context: db)
            try? db.save()
        }
    }
}
