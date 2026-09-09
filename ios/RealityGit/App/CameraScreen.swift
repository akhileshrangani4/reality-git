import RealityKit
import SwiftUI

enum AppPalette {
    static let controlRGB = SIMD3<Float>(repeating: 1)
    static var control: Color {
        Color(red: Double(controlRGB.x), green: Double(controlRGB.y), blue: Double(controlRGB.z))
    }
}

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
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("Settings")
                }
                Spacer()
                CaptureStatus(controller: controller, session: controller.objectSession,
                    assistant: controller.assistant, showsSettings: $showsSettings)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 22).foregroundStyle(.white)
        }
        .sheet(isPresented: $showsSettings) {
            CaptureSettings(assistant: controller.assistant, previewReference: $controller.previewReference,
                hasReference: controller.objectSession.reference != nil, canReset: controller.canReset,
                reset: controller.reset)
        }
        .task {
            await controller.assistant.restoreConnection()
            if !controller.assistant.signedIn { showsSettings = true }
            await controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await controller.start(); await controller.assistant.refreshAccount() } }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: String {
        if !controller.status.isReady { return controller.status.message }
        if !assistant.connected { return assistant.message }
        if !controller.hasSelection { return "Tap an object, or draw around it." }
        if controller.captureStage == .scanning { return "Scanning…" }
        if controller.captureStage == .forming { return "Capturing shape…" }
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
                if controller.captureStage != .idle {
                    if reduceMotion {
                        Image(systemName: "viewfinder").foregroundStyle(.white)
                    } else {
                        ProgressView().tint(AppPalette.control)
                    }
                }
                Text(text).font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: text)
            }
            if controller.status == .cameraDenied {
                Button("Allow camera") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.glassProminent).tint(AppPalette.control).foregroundStyle(.black)
            } else if !assistant.connected {
                Button(assistant.signedIn ? "Open Settings" : "Sign in with ChatGPT") { showsSettings = true }
                    .buttonStyle(.glassProminent).tint(AppPalette.control).foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .onChange(of: assistant.modelID) { old, new in
            if old != nil, old != new { controller.reset() }
        }
        .onChange(of: assistant.connected) { _, _ in controller.reset() }
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
