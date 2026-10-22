#if os(iOS)
import Foundation
import UIKit

/// SideStore lifecycle shim for a *fully integrated native* SideStore module.
/// The Nyxian host must also initialize SideStore's persistence/authentication
/// and correctly forward deep links, import intents and background callbacks.
/// This does not replace SideStore's existing AppDelegate initialization.
@MainActor
enum CrimsonSideStoreLifecycle {
    private static var bootstrapped = false

    static func onHostForeground() {
        // Nyxian's UIApplicationDelegate is not SideStore's AppDelegate.
        // Seed the real SideStore defaults and Core Data store before allowing
        // reconciliation or native installation. Never fabricate readiness
        // from mere presence of the importer Swift file.
        if !bootstrapped {
            bootstrapped = true
            UserDefaults.registerDefaults()
            BackgroundServiceManager.ensureBackgroundServicesStarted()
            Task.detached(priority: .utility) {
                do {
                    try await DatabaseManager.shared.start()
                    await AppManager.shared.reconcileInstalledApps()
                } catch {
                    // The native installer will independently surface any
                    // persistent-store failures to its own completion.
                    NSLog("[ROMSpace SideStore] Native database startup unavailable")
                }
            }
        } else {
            BackgroundServiceManager.ensureBackgroundServicesStarted()
            Task.detached(priority: .utility) {
                await AppManager.shared.reconcileInstalledApps()
            }
        }
    }

    static func onHostBackground() {
        // Keep SideStore's genuine refresh service registered, but do not
        // promise iOS will schedule a background execution window.
        BackgroundServiceManager.ensureBackgroundServicesStarted()
    }

    static func makeNativeImporter() -> CrimsonSideStoreImporter {
        CrimsonSideStoreImporter()
    }
}
#endif
