import SwiftUI

/// Template-colored vector of the read-more arrow and text lines. The parent
/// heading supplies its color; the icon never becomes a separate control.
nonisolated struct ReadMoreIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 12.207, y: 11.293))
        path.addLine(to: CGPoint(x: 12.2754, y: 11.3691))
        path.addCurve(to: CGPoint(x: 12.207, y: 12.707),
                      control1: CGPoint(x: 12.5957, y: 11.7619), control2: CGPoint(x: 12.5731, y: 12.3409))
        for point in [
            CGPoint(x: 7.70703, y: 17.207), CGPoint(x: 6.29297, y: 15.793),
            CGPoint(x: 9.08594, y: 13), CGPoint(x: 2, y: 13), CGPoint(x: 2, y: 11),
            CGPoint(x: 9.08594, y: 11), CGPoint(x: 6.29297, y: 8.20703), CGPoint(x: 7.70703, y: 6.79297)
        ] {
            path.addLine(to: point)
        }
        path.closeSubpath()
        path.addRect(CGRect(x: 13, y: 15, width: 9, height: 2))
        path.addRect(CGRect(x: 16, y: 11, width: 6, height: 2))
        path.addRect(CGRect(x: 13, y: 7, width: 9, height: 2))
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)))
    }
}
