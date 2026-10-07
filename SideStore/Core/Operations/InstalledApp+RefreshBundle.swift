import Foundation
import SideSign

extension InstalledApp {
    /// Call on this managed object's context, as with the other InstalledApp metadata reads.
    func loadBundleForRefreshing() throws -> ALTApplication {
        let resolved = RefreshBundleResolver.resolve(
            cachedURL: fileURL,
            isStoreApp: bundleIdentifier == StoreApp.altstoreAppID,
            installedBundleIdentifier: resignedBundleIdentifier,
            runningBundleIdentifier: Bundle.Info.activeBundle.bundleIdentifier,
            runningBundleURL: Bundle.Info.activeBundleURL,
            load: { ALTApplication(fileURL: $0) },
            identifier: { $0.bundleIdentifier })
        guard let resolved else {
            throw OperationError.invalidApp(reason: "The cached bundle for \(name) is missing or unreadable, and no matching installed bundle is available. Reinstall the same app over its existing installation to restore its cache.")
        }
        if resolved.usedRunningBundle {
            // Needs proper testing on-device after upgrades that remove the self-refresh cache.
            debugLog("[RefreshBundle] Using matching installed SideStore bundle for profile-only refresh.")
        }
        return resolved.metadata
    }
}
