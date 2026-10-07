import Foundation

@main
struct RefreshBundleTests {
    struct Metadata {
        let identifier: String
        let extensions: [String]
        let entitlements: [String: String]
    }

    static let identity = "com.SideStore.SideStore.TESTTEAM"
    static let running = Metadata(identifier: identity, extensions: [identity + ".Widget"],
                                  entitlements: ["application-identifier": "TESTTEAM." + identity])

    static func main() {
        let cachedURL = URL(fileURLWithPath: "/cache/App.app")
        let runningURL = URL(fileURLWithPath: "/installed/SideStore.app")
        let cached = Metadata(identifier: "com.SideStore.SideStore", extensions: [], entitlements: [:])
        var loads: [URL] = []
        func resolve(cache: Metadata? = nil, store: Bool = true, installed: String = RefreshBundleTests.identity,
                     active: String? = RefreshBundleTests.identity, live: Metadata? = RefreshBundleTests.running) -> RefreshBundleResolver.Resolved<Metadata>? {
            loads = []
            return RefreshBundleResolver.resolve(
                cachedURL: cachedURL, isStoreApp: store, installedBundleIdentifier: installed,
                runningBundleIdentifier: active, runningBundleURL: runningURL,
                load: { url in
                    loads.append(url)
                    return url == cachedURL ? cache : live
                }, identifier: { $0.identifier })
        }

        let existing = resolve(cache: cached)
        precondition(existing?.usedRunningBundle == false)
        precondition(existing?.metadata.identifier == cached.identifier)
        precondition(loads == [cachedURL]) // Preserve existing valid cache behavior.

        // A failed parser represents both an absent cache and an unreadable cached bundle.
        let restored = resolve()
        precondition(restored?.usedRunningBundle == true)
        precondition(restored?.metadata.extensions == running.extensions)
        precondition(restored?.metadata.entitlements == running.entitlements)
        precondition(loads == [cachedURL, runningURL])

        precondition(resolve(store: false, installed: "com.nuvio.App") == nil)
        precondition(loads == [cachedURL]) // Other apps must never borrow SideStore's metadata.
        precondition(resolve(installed: identity + ".Other") == nil)
        precondition(loads == [cachedURL])
        precondition(resolve(active: nil) == nil)
        precondition(loads == [cachedURL])
        precondition(resolve(installed: "", active: "") == nil)
        precondition(loads == [cachedURL])
        precondition(resolve(live: nil) == nil)
        precondition(resolve(live: cached) == nil) // Parsed ID must also match exactly.
        precondition(resolve(live: Metadata(identifier: identity + ".Widget", extensions: [], entitlements: [:])) == nil)
        print("Refresh bundle tests passed: valid cache, self recovery, extensions/entitlements, and identity rejection.")
    }
}
