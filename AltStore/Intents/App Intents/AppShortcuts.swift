//
//  AppShortcuts.swift
//  AltStore
//
//  Created by Riley Testut on 8/23/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

import AppIntents

@available(iOS 17, tvOS 17, *)
public struct ShortcutsProvider: AppShortcutsProvider
{
    public static var appShortcuts: [AppShortcut] {
        #if !os(tvOS)
        AppShortcut(intent: PrepareAppRefreshIntent(),
                    phrases: ["Prepare refresh with \(.applicationName)"],
                    shortTitle: "Prepare App Refresh", systemImageName: "arrow.down.doc")
        AppShortcut(intent: InstallPreparedRefreshIntent(),
                    phrases: ["Install prepared refresh with \(.applicationName)"],
                    shortTitle: "Install Prepared Refresh", systemImageName: "checkmark.seal")
        #endif
        AppShortcut(intent: RefreshAllAppsIntent(),
                    phrases: [
                        "Refresh \(.applicationName)",
                        "Refresh \(.applicationName) apps",
                        "Refresh my \(.applicationName) apps",
                        "Refresh apps with \(.applicationName)",
                    ],
                    shortTitle: "Refresh All Apps",
                    systemImageName: "arrow.triangle.2.circlepath")

        AppShortcut(intent: InstallIPAIntent(),
                    phrases: [
                        "Install IPA with \(.applicationName)",
                        "Install an IPA with \(.applicationName)",
                    ],
                    shortTitle: "Install IPA",
                    systemImageName: "square.and.arrow.down")
    }
    
    public static var shortcutTileColor: ShortcutTileColor {
        return .teal
    }
}
