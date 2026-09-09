import SwiftUI

@main
struct RealityGitApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--capture-preview") {
                CaptureEffectsPreview().ignoresSafeArea().preferredColorScheme(.dark)
            } else if ProcessInfo.processInfo.arguments.contains("--settings-preview") {
                SettingsPreview()
            } else {
                CameraScreen()
            }
            #else
            CameraScreen()
            #endif
        }
    }
}
