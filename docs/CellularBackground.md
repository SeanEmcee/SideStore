# Custom SideStore: themes and prepared cellular refresh

This fork adds interface color controls and two separate background Shortcuts actions. The original Wi-Fi refresh and foreground cellular flow remain available.

## Install the IPA

The GitHub Actions artifact contains an ad-hoc signed IPA for a sideloading tool to sign with your own Apple account. It is not an App Store or Apple distribution signed app.

Install it over the existing SideStore using the same account and bundle identifier. The base bundle identifier remains `com.SideStore.SideStore`; a signing tool may append your team identifier. An update with the same installed identifier replaces SideStore and uses its existing app slot. A different identifier installs a separate app and needs another slot. Keep the existing app and its data until the replacement is confirmed. Do not reset the pairing file or revoke certificates as an installation step.

Open SideStore once after installing, confirm your account and pairing configuration, and run a normal Wi-Fi refresh. The new prepared actions require cached app bundles, a valid existing signing certificate, and completed device registration. They renew provisioning profiles; they do not re-sign apps to a replacement certificate or import an app managed only by AltStore.

## Theme Manager

Go to **Settings → User Customizations → Theme Manager**.

The interface controls are Accent, Screen Background, Card Background, Text, Secondary Text, Navigation Bar, Tab Bar, and Dividers & Borders. Use each color picker, or enter `#RRGGBB` and tap Apply. The `#` is optional. Invalid input leaves the last valid color intact. Changes are saved locally and applied to shared UIKit surfaces and neutral SwiftUI colors across the app.

Reset beside a control restores that component. Reset to SideStore Classic restores all interface colors. Navigation and tab bars follow Screen Background unless given their own color. Secondary text follows the text color, with its existing opacity, unless given its own color. Preset themes select an accent. Choose dark text and secondary text when using a light background.

Images, app artwork, system alerts/color-picker windows, widgets, and semantic status colors have their own appearance; these are not a pixel-by-pixel skin editor. Some screens need to be revisited on older iOS releases. Live dynamic color updates use the iOS 17+ custom trait system.

## Create the cellular shortcut

Keep sing-box MT connected. Keep the working on-device reflection configuration and Tailscale routes. In SideStore, keep the known working explicit endpoint: **Use Local VPN off**, Device IP `10.7.0.1`, RemotePair Port `49152`, and your Remote Pairing file. Turning off Use Local VPN here changes endpoint discovery, not the sing-box VPN connection.

Build one shortcut with these actions in this order:

1. **SideStore → Prepare App Refresh**. Leave cellular data on for this action. It contacts Apple and returns a prepared job token.
2. **Set Cellular Data → Off**. Use the native Shortcuts action.
3. **SideStore → Install Prepared Refresh**. Set its Prepared Refresh field to the magic-variable output of step 1.
4. **Set Cellular Data → On**. Use the native Shortcuts action.
5. Optional **Show Notification**, using the text output from step 3.

Turn off Show When Run if offered by either SideStore action. No Open App, Run Shortcut TurnOffData, or Run Shortcut TurnOnData action is needed in this sequence. The original Refresh All Apps action still uses its original cellular behavior; use the two new actions for this test.

Preparation happens before data is disabled. Installation makes no Apple internet request and does not advance expiry merely because a profile was downloaded. It validates the account, app identity, certificate, and live device ID, installs profiles, then reads installed profiles back before saving expiry dates. Jobs expire after ten minutes and can be used once. Prepare a fresh job for every run.

Recoverable installation failures return a message instead of throwing, so step 4 can restore data. An iOS termination, shortcut cancellation, or process crash can still interrupt that sequence. If that happens, re-enable cellular data in Settings and prepare a new job.

## Verify before scheduling

1. On cellular, disconnect from Wi-Fi and run the new shortcut with the phone unlocked. Confirm it does not switch to SideStore or a helper shortcut, restores cellular data, reports verified installation, and records a successful refresh with a renewed expiry in SideStore.
2. Confirm Tailscale RDP still works after data is restored.
3. Create a temporary Time of Day personal automation that runs the new shortcut, choose Run Immediately, and schedule it a few minutes ahead. Lock the phone after it has been unlocked at least once since restart.
4. After the scheduled run, verify data is on, the returned status indicates success, and SideStore's expiry and refresh history changed. A start notification alone does not prove success.

GitHub compilation, storage tests, and IPA checks establish that the code builds and is packaged. They do not establish that iOS permits this workflow while locked. A completed scheduled phone test is required before relying on unattended renewal.

## Build

The workflow `.github/workflows/cellular-background.yml` runs on the `cellular-background` branch. It tests single-use job storage, archives the iOS app with Xcode, packages the IPA, checks the bundle and intent symbols, and uploads the IPA, checksum, and build log. Pairing files and Apple signing credentials are not required or uploaded by this workflow.
