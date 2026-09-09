#if DEBUG
import SwiftUI

/// Screenshots use the actual views and, for the connected states, the paired account.
struct SettingsPreview: View {
    @StateObject private var assistant = AssistantCoordinator()
    private let arguments = ProcessInfo.processInfo.arguments

    var body: some View {
        Group {
            if arguments.contains("--models-preview") {
                NavigationStack { ScanModelPicker(assistant: assistant, reset: {}) }.tint(.primary)
            } else {
                CaptureSettings(assistant: assistant, previewReference: .constant(true), hasReference: false,
                    canReset: false, reset: {})
            }
        }
        .preferredColorScheme(arguments.contains("--dark-preview") ? .dark : .light)
        .dynamicTypeSize(arguments.contains("--large-text-preview") ? .accessibility3 : .large)
        .task {
            if !arguments.contains("--connect-preview") { await assistant.restoreConnection() }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: \.isKeyWindow) else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = arguments.contains("--models-preview") ? "models" : arguments.contains("--connect-preview") ? "connect" : "settings"
            let style = arguments.contains("--dark-preview") ? "dark" : "light"
            let size = arguments.contains("--large-text-preview") ? "large" : "normal"
            let file = URL.documentsDirectory.appendingPathComponent("\(name)-\(style)-\(size).png")
            if let data = image.pngData() {
                do { try data.write(to: file); print("Settings preview saved \(file.lastPathComponent)") }
                catch { print("Settings preview failed") }
            }
        }
    }
}
#endif
