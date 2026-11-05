# EQBrowser (iPhone / iPad spike)

A `WKWebView` browser that loads YouTube Music and injects `web/ytm-eq.js`, the same EQ as the Mac app, into the page. Free sideload route: Xcode signs it with your Apple ID, and it expires after 7 days.

## One-time setup

1. Open Xcode → File → New → Project → iOS → **App**. Name it `EQBrowser`, interface SwiftUI, language Swift. Save it inside `ios/` so the project sits next to these files.
2. Delete the generated `ContentView.swift` and `EQBrowserApp.swift`, then drag in the two files from this folder (choose "Copy items if needed" off, target EQBrowser on).
3. Add the EQ script to the app bundle: drag `web/ytm-eq.js` into the project navigator, check "Add to targets: EQBrowser", and make sure it appears under Build Phases → Copy Bundle Resources.
4. Target → Signing & Capabilities: choose **Team: Your Name (Personal Team)**. Xcode may ask you to sign in with your Apple ID under Settings → Accounts first.
5. Still under Signing & Capabilities, click **+ Capability → Background Modes** and tick **Audio, AirPlay, and Picture in Picture**. This is what lets audio continue in the background.

## Put it on your device

1. Connect the iPhone or iPad with a cable. On the device, turn on **Settings → Privacy & Security → Developer Mode** (it restarts the device).
2. In Xcode, pick the device from the run-destination menu and press Run.
3. On the device, go to **Settings → General → VPN & Device Management**, tap your Apple ID under Developer App, and choose Trust.

## Limits of the free route

- The signature expires after 7 days. Rebuild and run again from Xcode to refresh it.
- You can have only a few sideloaded apps at once.
- Installing from Xcode only works while the device is connected to this Mac.

## What to check in the spike

- Music plays through the EQ: open the EQ panel that `ytm-eq.js` adds to the page and move a slider.
- Background: start a song, lock the screen, and see whether it keeps playing and whether the EQ stays active. Report what happens.
