import RealityKit
import RealityGitCore
import UIKit

@MainActor
final class DiffRenderer {
    private var red: AnchorEntity?
    private var green: AnchorEntity?
    private var referenceKey: ObservationKey?
    func reset() {
        red?.removeFromParent(); green?.removeFromParent()
        red = nil; green = nil; referenceKey = nil
    }
    func update(in view: ARView, reference: ReferenceState?, current: SIMD3<Float>?,
                showRed: Bool, showGreen: Bool, reliable: Bool) {
        guard let reference else { reset(); return }
        if referenceKey != reference.captureKey {
            reset(); referenceKey = reference.captureKey
            red = box(position: reference.position, size: reference.bounds, color: .systemRed)
            green = box(position: reference.position, size: reference.bounds, color: .systemGreen)
            if let red { view.scene.addAnchor(red) }
            if let green { view.scene.addAnchor(green) }
        }
        red?.isEnabled = reliable && showRed
        green?.isEnabled = reliable && showGreen && current != nil
        if let current { green?.setPosition(current, relativeTo: nil) }
    }
    private func box(position: SIMD3<Float>, size: SIMD3<Float>, color: UIColor) -> AnchorEntity {
        let anchor = AnchorEntity(world: position)
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
        anchor.addChild(entity)
        return anchor
    }
}
