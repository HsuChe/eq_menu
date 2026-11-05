import AVFoundation
import SwiftUI

@main
struct EQBrowserApp: App {
    init() {
        // Playback category keeps audio going when the mute switch is on and
        // lets it continue in the background once the Background Modes capability is set.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("EQBrowser: audio session setup failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
