import RealityKit
import SwiftUI

struct CameraScreen: View {
    @StateObject private var controller = ARSessionController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            CameraView(arView: controller.arView)
                .ignoresSafeArea()

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
                        Text(controller.status.title)
                            .font(.headline)
                        Spacer()
                        if controller.hasDepth {
                            Text("DEPTH READY")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.mint)
                        }
                    }

                    Text(controller.status.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
                        Button("Place a new marker", systemImage: "arrow.counterclockwise") {
                            controller.reset()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityHint("Starts a fresh room scan and replaces the test marker.")
                    }

                    Text("WORLD TRACKING CHECK · 01")
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
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
