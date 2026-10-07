import Foundation

/// Profile-only refresh can read the running store's metadata when its cache is absent.
/// This does not supply a payload for installation, updates, or re-signing.
enum RefreshBundleResolver {
    struct Resolved<Metadata> {
        let metadata: Metadata
        let usedRunningBundle: Bool
    }

    static func resolve<Metadata>(
        cachedURL: URL,
        isStoreApp: Bool,
        installedBundleIdentifier: String,
        runningBundleIdentifier: String?,
        runningBundleURL: URL,
        load: (URL) -> Metadata?,
        identifier: (Metadata) -> String
    ) -> Resolved<Metadata>? {
        if let cached = load(cachedURL) {
            return Resolved(metadata: cached, usedRunningBundle: false)
        }
        guard isStoreApp,
              !installedBundleIdentifier.isEmpty,
              runningBundleIdentifier == installedBundleIdentifier,
              let running = load(runningBundleURL),
              identifier(running) == installedBundleIdentifier else {
            return nil
        }
        return Resolved(metadata: running, usedRunningBundle: true)
    }
}
