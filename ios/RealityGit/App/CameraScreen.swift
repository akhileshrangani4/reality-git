import RealityKit
import SwiftUI

struct CameraScreen: View {
    @StateObject private var controller = ARSessionController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false

    var body: some View {
        ZStack {
            CameraView(controller: controller).ignoresSafeArea()
            if let rect = controller.dragRect ?? controller.selectionRect {
                RoundedRectangle(cornerRadius: 8)
                    .fill(controller.currentScreenOverlay == nil ? Color.clear : Color.green.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(
                            controller.currentScreenOverlay == nil ? Color.white.opacity(0.8) : Color.green.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2, dash: controller.dragRect == nil ? [] : [6, 4]))
                    }
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            }
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.5)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack {
                    Text("Reality Git").font(.headline)
                    Spacer()
                    Button { showsSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Settings")
                }
                Spacer()
                CaptureStatus(controller: controller, session: controller.objectSession,
                    assistant: controller.assistant, showsSettings: $showsSettings)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 22).foregroundStyle(.white)
        }
        .sheet(isPresented: $showsSettings) { CaptureSettings(controller: controller, assistant: controller.assistant) }
        .task {
            if !controller.assistant.connected, let saved = UserDefaults.standard.string(forKey: "lastMacAddress") {
                controller.assistant.connect(address: saved)
            }
            await controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await controller.start() } }
            else if phase == .background { controller.pause() }
        }
        .onDisappear { controller.pause() }
    }
}

private struct CaptureStatus: View {
    @ObservedObject var controller: ARSessionController
    @ObservedObject var session: SessionCoordinator
    @ObservedObject var assistant: AssistantCoordinator
    @Binding var showsSettings: Bool
    @Environment(\.openURL) private var openURL

    private var text: String {
        if !controller.status.isReady { return controller.status.message }
        if !assistant.connected { return "Let Astra remember where things belong." }
        if !controller.hasSelection { return "Tap an object, or draw around it." }
        if session.reference == nil { return assistant.message }
        if session.state == .absent { return "Gone · red marks its place" }
        if session.state == .moved {
            let lastSeen = session.observedPosition(now: controller.arView.session.currentFrame?.timestamp ?? .infinity)
            return session.current == nil && lastSeen != nil ? "Moved · last seen in green" : "Moved · red marks its place"
        }
        if session.current == nil { return assistant.message }
        return "Remembered · try moving it"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if assistant.isThinking && session.reference == nil {
                    ProgressView().tint(.white)
                }
                Text(text).font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if controller.status == .cameraDenied {
                Button("Allow camera") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            } else if !assistant.connected {
                Button("Connect Astra") { showsSettings = true }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }
}

private struct CaptureSettings: View {
    @ObservedObject var controller: ARSessionController
    @ObservedObject var assistant: AssistantCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var address = UserDefaults.standard.string(forKey: "lastMacAddress") ?? "http://"

    var body: some View {
        NavigationStack {
            Form {
                Section("Astra connection") {
                    TextField("http://your-mac.local:8080", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("Astra recognizes and finds your object. Camera images go through your local server to OpenAI; your iPhone supplies depth and places the overlays.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(assistant.connected ? "Reconnect" : "Connect") {
                        if assistant.connect(address: address) {
                            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "lastMacAddress")
                            controller.reset()
                            dismiss()
                        }
                    }
                    if assistant.connected {
                        Button("Disconnect") {
                            assistant.disconnect()
                            UserDefaults.standard.removeObject(forKey: "lastMacAddress")
                            controller.reset()
                            dismiss()
                        }
                    }
                    Text(assistant.message).font(.caption).foregroundStyle(.secondary)
                }
                if controller.objectSession.reference != nil {
                    Section {
                        Toggle("Show remembered shape", isOn: $controller.previewReference)
                        Button("Start over") { controller.reset(); dismiss() }
                    }
                } else if controller.canReset {
                    Button("Restart camera") { controller.reset(); dismiss() }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CameraView: UIViewRepresentable {
    let controller: ARSessionController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> ARView {
        let view = controller.arView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let controller: ARSessionController
        private var start: CGPoint?

        init(controller: ARSessionController) { self.controller = controller }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            controller.select(point: gesture.location(in: controller.arView))
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let current = gesture.location(in: controller.arView)
            switch gesture.state {
            case .began:
                start = current
            case .changed:
                guard let start else { return }
                controller.dragRect = box(start, current)
            case .ended:
                defer { start = nil; controller.dragRect = nil }
                guard let start else { return }
                let rect = box(start, current)
                if rect.width >= 20 && rect.height >= 20 { controller.select(rect: rect) }
            case .cancelled, .failed:
                start = nil
                controller.dragRect = nil
            default:
                break
            }
        }

        private func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }
}
