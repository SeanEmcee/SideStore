import Foundation

@main
struct PreparedRefreshTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreparedRefreshJobStore(directory: folder)
        let now = Date()
        let app = PreparedRefreshJob.App(bundleIdentifier: "test.app", resignedBundleIdentifier: "test.app.TEAM", certificateSerial: "TEST", profiles: ["test.app": Data([1, 2, 3])])
        let job = PreparedRefreshJob(version: 1, createdAt: now, teamIdentifier: "TEAM", apps: [app])
        let token = try store.save(job, now: now)
        let loaded = try store.claim(token, now: now)
        precondition(loaded.apps.first?.profiles["test.app"] == Data([1, 2, 3]))
        do { _ = try store.claim(token, now: now); fatalError("Job replay was accepted") }
        catch PreparedRefreshError.invalidJob {}
        do { _ = try store.claim("../escape", now: now); fatalError("Invalid token was accepted") }
        catch PreparedRefreshError.invalidJob {}
        let expired = try store.save(job, now: now)
        do { _ = try store.claim(expired, now: now.addingTimeInterval(601)); fatalError("Expired job was accepted") }
        catch PreparedRefreshError.expiredJob {}
        do { _ = try store.claim(expired, now: now); fatalError("Expired claimed job survived") }
        catch PreparedRefreshError.invalidJob {}
        let duplicate = PreparedRefreshJob(version: 1, createdAt: now, teamIdentifier: "TEAM", apps: [app, app])
        do { _ = try store.save(duplicate, now: now); fatalError("Duplicate app was accepted") }
        catch PreparedRefreshError.invalidJob {}
        let missingMain = PreparedRefreshJob.App(bundleIdentifier: "test.app", resignedBundleIdentifier: "test.app.TEAM", certificateSerial: "TEST", profiles: ["other.app": Data([1])])
        do { _ = try store.save(.init(version: 1, createdAt: now, teamIdentifier: "TEAM", apps: [missingMain]), now: now); fatalError("Missing main profile was accepted") }
        catch PreparedRefreshError.invalidJob {}
        do { _ = try store.save(.init(version: 1, createdAt: now.addingTimeInterval(60), teamIdentifier: "TEAM", apps: [app]), now: now); fatalError("Future job was accepted") }
        catch PreparedRefreshError.expiredJob {}
        let tampered = try store.save(job, now: now)
        let invalid = PreparedRefreshJob(version: 99, createdAt: now, teamIdentifier: "TEAM", apps: [app])
        try JSONEncoder().encode(invalid).write(to: folder.appendingPathComponent(tampered + ".json"))
        do { _ = try store.claim(tampered, now: now); fatalError("Invalid schema was accepted") }
        catch PreparedRefreshError.invalidJob {}
        do { _ = try store.claim(tampered, now: now); fatalError("Invalid claimed job survived") }
        catch PreparedRefreshError.invalidJob {}
        print("Prepared refresh storage: round-trip, replay, traversal, expiry, duplicate apps, missing profiles, future jobs, and tampered schema passed.")
    }
}
