import RealityKit
import SwiftUI

struct CameraScreen: View {
    @StateObject private var controller = ARSessionController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            CameraView(controller: controller)
                .ignoresSafeArea()

            if let rect = controller.dragRect ?? controller.selectionRect {
                Rectangle()
                    .fill(controller.currentScreenOverlay == nil ? Color.clear : Color.green.opacity(0.25))
                    .overlay {
                        Rectangle().strokeBorder(controller.currentScreenOverlay == nil ? Color.mint : Color.green,
                            style: StrokeStyle(lineWidth: 2, dash: controller.dragRect == nil ? [] : [6, 4]))
                    }
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            LinearGradient(
                colors: [.black.opacity(0.65), .clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("REALITY GIT")
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .tracking(3)
                        Text("A place to remember.")
                            .font(.title2.weight(.medium))
                    }
                    Spacer()
                    Image(systemName: "viewfinder")
                        .font(.title2)
                        .accessibilityHidden(true)
                }
                .padding(.top, 12)

                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.status.isReady ? Color.mint : Color.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(controller.hasSelection && controller.status.isReady ? "Object tracking" : controller.status.title)
                            .font(.headline)
                        Spacer()
                        if controller.hasDepth {
                            Text("DEPTH READY")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.mint)
                        }
                    }

                    Text(controller.hasSelection && controller.status.isReady ? controller.selectionMessage : controller.status.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if controller.status.isReady && !controller.hasSelection {
                        Text("Tap an object, or draw a box around it.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.mint)
                    }

                    if controller.status == .cameraDenied {
                        Button("Open Settings", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                        .foregroundStyle(.black)
                    } else if controller.canReset {
                        Button("Start over", systemImage: "arrow.counterclockwise") {
                            controller.reset()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityHint("Clears the reference and starts a fresh room scan.")
                    }

                    ReferenceStatus(session: controller.objectSession, screenTrackVisible: controller.currentScreenOverlay != nil)
                    if controller.objectSession.reference != nil {
                        Text(controller.ghostStatus).font(.caption2).foregroundStyle(.secondary)
                        Toggle("Preview remembered shape", isOn: $controller.previewReference).font(.caption)
                    }
                    AssistantControls(assistant: controller.assistant)

                    Text(controller.hasSelection ? "OBJECT TRACKING CHECK · 02" : "WORLD TRACKING CHECK · 01")
                        .font(.system(.caption2, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(.tertiary)
                }
                .padding(22)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
        .task {
            await controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await controller.start() }
            } else if phase == .background {
                controller.pause()
            }
        }
        .onDisappear {
            controller.pause()
        }
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

private struct AssistantControls: View {
    @ObservedObject var assistant: AssistantCoordinator
    @State private var showsConnection = false
    @State private var address = UserDefaults.standard.string(forKey: "lastMacAddress") ?? "http://"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(assistant.message).font(.caption).foregroundStyle(.secondary)
            if let semanticMessage = assistant.semanticMessage {
                Text(semanticMessage).font(.caption).foregroundStyle(.secondary)
            }
            Button("Mac assistance", systemImage: "laptopcomputer") { showsConnection = true }
                .font(.subheadline)
        }
        .sheet(isPresented: $showsConnection) {
            NavigationStack {
                Form {
                    Section("Nearby Mac") {
                        TextField("http://your-mac.local:8080", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("When connected, sampled camera images go to this nearby Mac for object tracking. Keep both devices on the same local network. When your Mac server has Astra enabled, selected image crops are also sent to OpenAI.")
                            .font(.footnote)
                        Button(assistant.connected ? "Reconnect" : "Connect") {
                            if assistant.connect(address: address) {
                                UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "lastMacAddress")
                                showsConnection = false
                            }
                        }
                        if assistant.connected {
                            Button("Disconnect") { assistant.disconnect(); showsConnection = false }
                        }
                        Text(assistant.message).font(.caption)
                    }
                }
                .navigationTitle("Mac assistance")
                .toolbar { Button("Done") { showsConnection = false } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct ReferenceStatus: View {
    @ObservedObject var session: SessionCoordinator
    let screenTrackVisible: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(screenTrackVisible ? (session.state == .absent ? "Object found · checking its position." : "Moved · following object in view; depth uncertain.") : session.message).font(.subheadline.weight(.medium)).foregroundStyle(.mint)
            if session.reference != nil {
                Text("Captured depth shape · original reference retained")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
