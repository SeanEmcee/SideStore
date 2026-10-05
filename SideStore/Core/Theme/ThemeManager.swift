//
//  ThemeManager.swift
//  SideStore
//
//  Created by Magesh K on 9/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import Combine

public struct ThemePreset: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let hex: String
    
    public var color: UIColor {
        UIColor(hex: hex) ?? .defaultAltPrimary
    }
    
    public static let presets: [ThemePreset] = [
        ThemePreset(id: "classic", name: "SideStore Teal", hex: "#19D3B5"),
        ThemePreset(id: "neonViolet", name: "Neon Violet", hex: "#8B5CF6"),
        ThemePreset(id: "sunsetCrimson", name: "Sunset Crimson", hex: "#EF4444"),
        ThemePreset(id: "sapphireBlue", name: "Sapphire Blue", hex: "#3B82F6"),
        ThemePreset(id: "cyberpunkGold", name: "Cyberpunk Gold", hex: "#F59E0B"),
        ThemePreset(id: "emeraldMint", name: "Emerald Mint", hex: "#10B981"),
        ThemePreset(id: "electricPink", name: "Electric Pink", hex: "#EC4899")
    ]
}

public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    public static let themeDidChangeNotification = Notification.Name("SideStoreThemeDidChangeNotification")

    private static let userDefaultsKey = "userCustomThemeHex"
    public enum ColorRole: String, CaseIterable, Identifiable {
        case accent, background, cards, text
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .accent: return "Accent"
            case .background: return "Screen Background"
            case .cards: return "Card Background"
            case .text: return "Text"
            }
        }
    }

    @Published private var customColors: [String: String]
    private let viewColors = NSMapTable<UIView, ViewColors>.weakToStrongObjects()

    public var backgroundColor: UIColor? { customColor(for: .background) }
    public var cardColor: UIColor? { customColor(for: .cards) }
    public var textColor: UIColor { customColor(for: .text) ?? .white }

    public func customColor(for role: ColorRole) -> UIColor? {
        if role == .accent { return primaryColor }
        return customColors[role.rawValue].flatMap { UIColor(hex: $0) }
    }

    public func color(for role: ColorRole) -> UIColor {
        customColor(for: role) ?? (role == .background ? UIColor(named: "SettingsBackground")! : role == .cards ? .white.withAlphaComponent(0.15) : .white)
    }

    /// Accept exactly six hex digits, with an optional leading #; never silently accept a partial parse.
    public static func normalizedHex(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, digits.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        return "#" + digits.uppercased()
    }

    @discardableResult
    public func setHex(_ value: String, for role: ColorRole) -> Bool {
        guard let hex = Self.normalizedHex(value), let color = UIColor(hex: hex) else { return false }
        if role == .accent { primaryColor = color }
        else {
            customColors[role.rawValue] = hex
            UserDefaults.standard.set(customColors, forKey: "userCustomInterfaceColors")
            notifyInterfaceChange()
        }
        return true
    }

    public func reset(_ role: ColorRole) {
        if role == .accent { resetToDefault(); return }
        customColors[role.rawValue] = nil
        UserDefaults.standard.set(customColors, forKey: "userCustomInterfaceColors")
        notifyInterfaceChange()
    }

    public func resetInterfaceColors() {
        customColors = [:]
        UserDefaults.standard.removeObject(forKey: "userCustomInterfaceColors")
        resetToDefault()
        notifyInterfaceChange()
    }

    @Published public var primaryColor: UIColor {
        didSet {
            UserDefaults.standard.set(primaryColor.hexString, forKey: Self.userDefaultsKey)
            NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: primaryColor)
            DispatchQueue.main.async {
                if let window = UIApplication.alt_shared?.alt_keyWindow {
                    window.tintColor = self.primaryColor
                    self.applyToVisibleInterface()
                }
            }
        }
    }

    private init() {
        customColors = UserDefaults.standard.dictionary(forKey: "userCustomInterfaceColors") as? [String: String] ?? [:]
        if let hex = UserDefaults.standard.string(forKey: Self.userDefaultsKey),
           let color = UIColor(hex: hex) {
            self.primaryColor = color
        } else {
            self.primaryColor = .defaultAltPrimary
        }
    }

    public func resetToDefault() {
        self.primaryColor = .defaultAltPrimary
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
    }

    private func notifyInterfaceChange() {
        NotificationCenter.default.post(name: Self.themeDidChangeNotification, object: nil)
        DispatchQueue.main.async { self.applyToVisibleInterface() }
    }

    /// Recolor neutral UI surfaces only. Images and semantic success/error/warning colors stay intact.
    public func applyToVisibleInterface() {
        guard let window = UIApplication.alt_shared?.alt_keyWindow else { return }
        window.tintColor = primaryColor
        apply(to: window)
    }

    private func apply(to view: UIView) {
        let state = viewColors.object(forKey: view) ?? ViewColors(view: view)
        viewColors.setObject(state, forKey: view)
        if let original = state.background, let role = state.backgroundRole {
            let target = customColor(for: role) ?? original
            if state.lastBackground == nil || view.backgroundColor == state.lastBackground || view.backgroundColor == original {
                if view.backgroundColor != target { view.backgroundColor = target }
                state.lastBackground = target
            }
        }
        if let label = view as? UILabel, let original = state.text {
            let target = customColor(for: .text)?.withAlphaComponent(original.cgColor.alpha) ?? original
            if state.lastText == nil || label.textColor == state.lastText || label.textColor == original {
                if label.textColor != target { label.textColor = target }
                state.lastText = target
            }
        }
        if let bar = view as? UINavigationBar, let color = backgroundColor {
            let appearance = bar.standardAppearance.copy()
            appearance.backgroundColor = color
            if let text = customColor(for: .text) {
                appearance.titleTextAttributes[.foregroundColor] = text
                appearance.largeTitleTextAttributes[.foregroundColor] = text
            }
            // Only assign on an actual color change to avoid a layout feedback loop.
            if bar.standardAppearance.backgroundColor != color {
                bar.standardAppearance = appearance
                bar.scrollEdgeAppearance = appearance
            }
        }
        for child in view.subviews { apply(to: child) }
    }

    private final class ViewColors {
        let background: UIColor?
        let backgroundRole: ColorRole?
        let text: UIColor?
        var lastBackground: UIColor?
        var lastText: UIColor?

        init(view: UIView) {
            let color = view.backgroundColor
            let screenColors = [UIColor(named: "Background"), UIColor(named: "SettingsBackground"), .systemBackground, .systemGroupedBackground].compactMap { $0 }
            let cardColors = [UIColor(named: "SettingsHighlighted"), .secondarySystemBackground, .secondarySystemGroupedBackground, .white.withAlphaComponent(0.15), .white.withAlphaComponent(0.25)].compactMap { $0 }
            func matches(_ value: UIColor?, _ colors: [UIColor]) -> Bool {
                guard let value else { return false }
                return colors.contains { value.resolvedColor(with: view.traitCollection) == $0.resolvedColor(with: view.traitCollection) }
            }
            backgroundRole = matches(color, screenColors) ? .background : matches(color, cardColors) ? .cards : nil
            background = backgroundRole != nil ? color : nil
            let labelColor = (view as? UILabel)?.textColor
            if let labelColor {
                var white: CGFloat = 0
                var alpha: CGFloat = 0
                let neutral = labelColor.getWhite(&white, alpha: &alpha) && white > 0.95
                text = neutral || matches(labelColor, [.label, .secondaryLabel, .tertiaryLabel]) ? labelColor : nil
            } else { text = nil }
        }
    }
}

public extension UIColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hexSanitized.hasPrefix("#") {
            hexSanitized.remove(at: hexSanitized.startIndex)
        }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

        let r, g, b, a: CGFloat
        if hexSanitized.count == 6 {
            r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgbValue & 0x0000FF) / 255.0
            a = 1.0
        } else if hexSanitized.count == 8 {
            r = CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgbValue & 0x000000FF) / 255.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var rgbComponents: (r: Int, g: Int, b: Int) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255), Int(g * 255), Int(b * 255))
    }

    var hslComponents: (h: Int, s: Int, l: Int) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)

        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal

        var h: CGFloat = 0
        var s: CGFloat = 0
        let l: CGFloat = (maxVal + minVal) / 2.0

        if delta != 0 {
            s = l > 0.5 ? delta / (2.0 - maxVal - minVal) : delta / (maxVal + minVal)

            if maxVal == r {
                h = (g - b) / delta + (g < b ? 6 : 0)
            } else if maxVal == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6.0
        }

        return (Int(h * 360), Int(s * 100), Int(l * 100))
    }
}
