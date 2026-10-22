#if os(iOS)
import Foundation
import UIKit

/// SideStore lifecycle shim for a *fully integrated native* SideStore module.
/// The Nyxian host must also initialize SideStore's persistence/authentication
/// and correctly forward deep links, import intents and background callbacks.
/// This does not replace SideStore's existing AppDelegate initialization.
@MainActor
enum CrimsonSideStoreLifecycle {
    static func onHostForeground() {
        // Preserve the genuine SideStore background services and bookkeeping.
        BackgroundServiceManager.ensureBackgroundServicesStarted()
        Task.detached {
            await AppManager.shared.reconcileInstalledApps()
        }
    }

    static func makeNativeImporter() -> CrimsonSideStoreImporter {
        CrimsonSideStoreImporter()
    }
}
#endif
