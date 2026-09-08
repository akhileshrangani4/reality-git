import CoreGraphics
import Foundation

public enum ImageCoordinates {
    public static func imagePoint(viewPoint: CGPoint, viewport: CGSize,
                                  displayTransform: CGAffineTransform) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0,
              abs(displayTransform.a * displayTransform.d - displayTransform.b * displayTransform.c) > 1e-8 else { return nil }
        let normalized = CGPoint(x: viewPoint.x / viewport.width, y: viewPoint.y / viewport.height)
        let image = normalized.applying(displayTransform.inverted())
        guard image.x.isFinite, image.y.isFinite,
              (0...1).contains(image.x), (0...1).contains(image.y) else { return nil }
        return image
    }

    public static func topLeftRect(visionRect: CGRect) -> CGRect {
        CGRect(x: visionRect.minX, y: 1 - visionRect.maxY,
               width: visionRect.width, height: visionRect.height)
    }

    public static func visionRect(topLeftRect: CGRect) -> CGRect {
        CGRect(x: topLeftRect.minX, y: 1 - topLeftRect.maxY,
               width: topLeftRect.width, height: topLeftRect.height)
    }
}
