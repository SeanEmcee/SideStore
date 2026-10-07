import Foundation
import CoreData
import SideSign
import Minimuxer
import MinimuxerCommon

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
            let context = try await db.perform {
                let context = InstallAppOperationContext(
                    pipelineSteps: PipelineStepDefinition.refresh,
                    bundleIdentifier: app.bundleIdentifier,
                    dbBackgroundContext: db, sharedContext: shared,
                    handler: PipelineHandler(),
                    activeSigningCertificate: CertificateManager.shared.activeCertificate?.certificate)
                context.installedApp = app
                context.customBundleIdentifier = app.customBundleIdentifier
                context.useMainProfile = app.useMainProfile
                context.targetAppBundle = try app.loadBundleForRefreshing()
                return context
            }
            AppManager.shared.set(Progress(totalUnitCount: 100), for: .refresh(app))
            defer { AppManager.shared.set(nil, for: .refresh(app)) }
            // Reuse upstream's certificate selection, verification and Apple profile requests.
            // No re-signing, certificate revocation, device registration, or installation here.
            try await UpdateAppCertificateOperation(context: context).execute()
            try await VerifyCertificateOperation(context: context, willResign: false).execute()
            let fetchedProfiles = try await FetchProvisioningProfilesOperation(context: context).execute()
            let snapshot = await db.perform {
                // certificateSerialNumber is an optional custom override, not the app's actual signer.
                // Use the same certificate source as upstream's verification-only refresh operation.
                (bundleIdentifier: app.bundleIdentifier, resignedBundleIdentifier: app.resignedBundleIdentifier,
                 name: app.name, certificateSerial: CertificateManager.shared.getSigningCertificate(for: app)?.serialNumber)
            }
            guard let certificateSerial = snapshot.certificateSerial, !certificateSerial.isEmpty else {
                throw PreparedRefreshError.configuration("The signing certificate for \(snapshot.name) could not be read. Reinstall that app over its existing installation on Wi-Fi to restore its cached certificate.")
            }
            let profiles = try PreparedRefreshJob.normalizedProfileKeys(fetchedProfiles,
                effectiveBundleIdentifier: context.targetBundleIdentifier, bundleIdentifier: snapshot.bundleIdentifier)
            guard let main = profiles[snapshot.bundleIdentifier] else {
                throw PreparedRefreshError.configuration("No main provisioning profile was returned for \(snapshot.name).")
            }
            guard main.bundleIdentifier == snapshot.resignedBundleIdentifier else {
                throw PreparedRefreshError.configuration("The downloaded profile for \(snapshot.name) targets a different installed app identity. Check that app's bundle ID and profile customizations.")
            }
            for profile in profiles.values {
                guard profile.teamIdentifier == team.identifier, profile.expirationDate > Date(),
                      profile.certificates.contains(where: { $0.serialNumber == certificateSerial }) else {
                    throw PreparedRefreshError.configuration("A downloaded profile for \(snapshot.name) does not match its installed signing certificate and account.")
                }
            }
            entries.append(.init(bundleIdentifier: snapshot.bundleIdentifier, resignedBundleIdentifier: snapshot.resignedBundleIdentifier,
                                 certificateSerial: certificateSerial, profiles: profiles.mapValues(\.data)))
        }
        let token = try store.save(.init(version: 1, createdAt: Date(), teamIdentifier: team.identifier, apps: entries))
        debugLog("[PreparedRefresh] Prepared profiles for \(entries.count) app(s). No device installation performed.")
        return token
    }

    /// Return a status for recoverable errors without launching any helper shortcuts.
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
            let binding = try DeviceSocketBinding.activateIfAvailable(
                allowDirectHandshake: PairingFileManager.shared.preferredProtocol == .rppairing)
            defer { DeviceSocketBinding.deactivate() }
            if let binding = binding {
                debugLog("[VPNBound] activated for prepared installation: interface=\(binding.interfaceName), source=\(binding.localIP), target=\(binding.targetIP)")
            } else {
                debugLog("[VPNBound] inactive: Wi-Fi has an address or the expected VPN is unavailable; using the existing transport")
            }
            var ready = false
            var lastReadinessError: Error?
            do {
                try await minimuxerStart(pairing, preferred: PairingFileManager.shared.preferredProtocol)
                (ready, lastReadinessError) = try await waitForDeviceReadiness()
            } catch {
                try Task.checkCancellation()
                lastReadinessError = error
            }
            if !ready {
                let recovery = LocalVPNRecovery()
                let failure = lastReadinessError?.localizedDescription ?? ""
                do {
                    if try await recovery.attempt(token: LocalVPNRecoveryKey.load(),
                        isCellularVPN: binding?.targetIP == "10.7.0.1",
                        isRemotePairing: PairingFileManager.shared.preferredProtocol == .rppairing,
                        failure: failure) {
                        debugLog("[VPNRecovery] controller acknowledged settings reapply; verifying a fresh handshake")
                        try Task.checkCancellation()
                        try await minimuxerStop() // Discard the old gateway adapter and pairing handshake.
                        DeviceSocketBinding.deactivate()
                        // Re-enumerate: the old utun index may no longer identify the active tunnel.
                        let deadline = Date().addingTimeInterval(3)
                        var rebound = false
                        while Date() < deadline {
                            try Task.checkCancellation()
                            if let fresh = try DeviceSocketBinding.activateIfAvailable(allowDirectHandshake: true) {
                                debugLog("[VPNRecovery] rebound: interface=\(fresh.interfaceName), source=\(fresh.localIP), target=\(fresh.targetIP)")
                                rebound = true
                                break
                            }
                            try await Task.sleep(nanoseconds: 200_000_000)
                        }
                        guard rebound else {
                            throw PreparedRefreshError.configuration("The recovery VPN did not return its expected local device address.")
                        }
                        try await minimuxerStart(pairing, preferred: .rppairing)
                        (ready, lastReadinessError) = try await waitForDeviceReadiness()
                        debugLog("[VPNRecovery] fresh handshake ready=\(ready)")
                    } else {
                        debugLog("[VPNRecovery] skipped: not configured or not an eligible cellular TCP failure")
                    }
                } catch {
                    try Task.checkCancellation()
                    debugLog("[VPNRecovery] recovery failed: \(error.localizedDescription)")
                    throw PreparedRefreshError.configuration("The local device connection failed. Original: \(failure) Recovery: \(error.localizedDescription)")
                }
            }
            guard ready else {
                let reason = lastReadinessError.map { " Details: \($0.localizedDescription)" } ?? ""
                throw PreparedRefreshError.configuration("The local device connection did not become ready.\(reason)")
            }
            let liveUDID = try await fetchUDID(forceLive: true)
            for entry in job.apps {
                try Task.checkCancellation()
                let app = try await db.perform { () throws -> InstalledApp in
                    guard let app = InstalledApp.first(satisfying: NSPredicate(format: "bundleIdentifier == %@", entry.bundleIdentifier), in: db),
                          app.isActive,
                          entry.matchesInstalledIdentity(bundleIdentifier: app.bundleIdentifier,
                              resignedBundleIdentifier: app.resignedBundleIdentifier,
                              signingCertificateSerial: CertificateManager.shared.getSigningCertificate(for: app)?.serialNumber) else {
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
            DeviceSocketBinding.deactivate()
            await minimuxer.network.refreshEndpoint() // Restore measured reachability after the diagnostic scope.
            await recordAttempt(db: db, error: nil)
            return "Refreshed \(completed) app(s). Installed profiles verified through the local device connection."
        } catch {
            DeviceSocketBinding.deactivate()
            await minimuxer.network.refreshEndpoint()
            let db = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            await recordAttempt(db: db, error: error)
            debugLog("[PreparedRefresh] Installation failed after \(completed) app(s): \(error.localizedDescription)")
            return "Refresh failed after \(completed) app(s): \(error.localizedDescription). Prepare a new refresh to retry."
        }
    }

    private func waitForDeviceReadiness() async throws -> (Bool, Error?) {
        // TCP preflight is skipped only in the scoped experiment; readiness still pairs for real.
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        while Date() < deadline {
            try Task.checkCancellation()
            await minimuxer.network.refreshEndpoint()
            let result = await minimuxer.core.isReady(withNetworkCheck: false)
            if case .success(true) = result { return (true, nil) }
            if case .failure(let error) = result {
                lastError = error
                debugLog("[PreparedRefresh] Device readiness failed: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return (false, lastError)
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
