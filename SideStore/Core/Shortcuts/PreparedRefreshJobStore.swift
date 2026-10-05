import Foundation

struct PreparedRefreshJob: Codable, Sendable {
    struct App: Codable, Sendable {
        let bundleIdentifier: String
        let resignedBundleIdentifier: String
        let certificateSerial: String
        let profiles: [String: Data]

        /// Compare the actual signing certificate again before installing a prepared profile.
        /// The database's optional custom-certificate override is not an installed identity.
        func matchesInstalledIdentity(bundleIdentifier: String, resignedBundleIdentifier: String,
                                      signingCertificateSerial: String?) -> Bool {
            self.bundleIdentifier == bundleIdentifier && self.resignedBundleIdentifier == resignedBundleIdentifier &&
                !certificateSerial.isEmpty && signingCertificateSerial == certificateSerial
        }
    }

    let version: Int
    let createdAt: Date
    let teamIdentifier: String
    let apps: [App]

    /// Upstream keys profiles by the customized target ID. Store them using database IDs so
    /// the main app and its extensions can be looked up consistently during installation.
    static func normalizedProfileKeys<Value>(_ profiles: [String: Value], effectiveBundleIdentifier: String,
                                             bundleIdentifier: String) throws -> [String: Value] {
        guard !effectiveBundleIdentifier.isEmpty, !bundleIdentifier.isEmpty else { throw PreparedRefreshError.invalidJob }
        var normalized: [String: Value] = [:]
        for (key, value) in profiles {
            guard key == effectiveBundleIdentifier || key.hasPrefix(effectiveBundleIdentifier + ".") else {
                throw PreparedRefreshError.configuration("A provisioning profile was returned for an unexpected app identity.")
            }
            let normalizedKey = bundleIdentifier + key.dropFirst(effectiveBundleIdentifier.count)
            normalized[normalizedKey] = value
        }
        return normalized
    }
}

enum PreparedRefreshError: LocalizedError {
    case invalidJob, expiredJob, busy, configuration(String)

    var errorDescription: String? {
        switch self {
        case .invalidJob: return "This prepared refresh is missing, invalid, or already used. Prepare a new refresh."
        case .expiredJob: return "The prepared refresh expired. Prepare a new refresh with internet access."
        case .busy: return "Another app operation is running. Try again after it finishes."
        case .configuration(let message): return message
        }
    }
}

/// Short-lived, single-use records contain profiles, never Apple passwords or pairing keys.
struct PreparedRefreshJobStore {
    static let lifetime: TimeInterval = 600
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func save(_ job: PreparedRefreshJob, now: Date = Date()) throws -> String {
        try validate(job, now: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // Scheduled refresh after first unlock must remain able to read this file while locked.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        try removeExpired(now: now)
        let token = UUID().uuidString
        let data = try JSONEncoder().encode(job)
        guard data.count <= 32 * 1024 * 1024 else { throw PreparedRefreshError.invalidJob }
        #if os(iOS)
        try data.write(to: url(for: token), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(for: token), options: .atomic)
        #endif
        return token
    }

    /// Rename atomically before reading: concurrent invocations cannot install the same job twice.
    func claim(_ token: String, now: Date = Date()) throws -> PreparedRefreshJob {
        guard UUID(uuidString: token)?.uuidString == token else { throw PreparedRefreshError.invalidJob }
        let source = url(for: token)
        let claimed = directory.appendingPathComponent(token + ".installing")
        do { try FileManager.default.moveItem(at: source, to: claimed) }
        catch { throw PreparedRefreshError.invalidJob }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let data = try Data(contentsOf: claimed)
        guard data.count <= 32 * 1024 * 1024 else { throw PreparedRefreshError.invalidJob }
        let job = try JSONDecoder().decode(PreparedRefreshJob.self, from: data)
        try validate(job, now: now)
        return job
    }

    private func url(for token: String) -> URL {
        directory.appendingPathComponent(token + ".json")
    }

    private func validate(_ job: PreparedRefreshJob, now: Date) throws {
        guard job.version == 1, !job.teamIdentifier.isEmpty, !job.apps.isEmpty,
              Set(job.apps.map(\.bundleIdentifier)).count == job.apps.count,
              job.apps.allSatisfy({ !$0.bundleIdentifier.isEmpty && !$0.resignedBundleIdentifier.isEmpty &&
                  $0.profiles[$0.bundleIdentifier] != nil && !$0.certificateSerial.isEmpty &&
                  $0.profiles.values.allSatisfy { !$0.isEmpty } })
        else { throw PreparedRefreshError.invalidJob }
        let age = now.timeIntervalSince(job.createdAt)
        guard age >= -5, age < Self.lifetime else { throw PreparedRefreshError.expiredJob }
    }

    private func removeExpired(now: Date) throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            guard ["json", "installing"].contains(file.pathExtension),
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) >= Self.lifetime { try FileManager.default.removeItem(at: file) }
        }
    }
}
