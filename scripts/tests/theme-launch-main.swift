import UIKit

// Only app-specific color helpers are substituted; the test compiles the real ThemeManager.
extension UIColor {
    static let defaultAltPrimary = UIColor.systemTeal
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

@main
final class ThemeLaunchDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Theme Test", sessionRole: session.role)
        config.delegateClass = ThemeLaunchScene.self
        return config
    }
}

final class ThemeLaunchScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var completed = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { fatalError("Missing window scene") }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .systemBackground
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !completed, let window, let view = window.rootViewController?.view else { return }
        completed = true
        let theme = ThemeManager.shared
        // A fresh window has no custom override. The first call crashed bg.7 here.
        theme.applyToVisibleInterface()
        theme.applyToVisibleInterface()
        precondition(theme.setHex("#123456", for: .background))
        theme.applyToVisibleInterface()
        precondition(view.backgroundColor == UIColor(hex: "#123456"))
        theme.reset(.background)
        theme.applyToVisibleInterface()
        precondition(view.backgroundColor == .systemBackground)
        print("THEME_LAUNCH_PASS: first activation, repeat application, color change, and reset")
        exit(0)
    }
}
