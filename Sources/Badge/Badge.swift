import AppKit
import SwiftUI

/// Vimium's badge look: a yellow gradient, a darker amber border, a light shadow, dark bold uppercase
/// letters, and typed letters dimmed to the border's amber.
@MainActor
public enum BadgeStyle {
    public static let font = NSFont.boldSystemFont(ofSize: 11)
    public static let text = NSColor(srgbRed: 0.19, green: 0.15, blue: 0.02, alpha: 1)
    public static let typedText = NSColor(srgbRed: 0.83, green: 0.67, blue: 0.23, alpha: 1)
    public static let fillTop = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.52, alpha: 1)
    public static let fillBottom = NSColor(srgbRed: 1.0, green: 0.77, blue: 0.26, alpha: 1)
    public static let border = NSColor(srgbRed: 0.76, green: 0.54, blue: 0.13, alpha: 1)
    public static let shadow = NSColor(white: 0, alpha: 0.3)
    public static let padding = NSSize(width: 3, height: 1)
    public static let cornerRadius: CGFloat = 3
    public static let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [fillTop.cgColor, fillBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
}

/// The hint badge as a keycap with ⌘ on it. Every measure is a fraction of the badge's side, taken
/// from its top-left corner, as in the approved sketch.
public struct AppIcon: View {
    let size: CGFloat

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        let s = size
        let keycap = RoundedRectangle(cornerRadius: 0.225 * s, style: .continuous)
        let face = RoundedRectangle(cornerRadius: 0.182 * s, style: .continuous)
        ZStack(alignment: .topLeading) {
            face
                .fill(LinearGradient(colors: [Color(nsColor: BadgeStyle.fillTop), Color(nsColor: BadgeStyle.fillBottom)], startPoint: .top, endPoint: .bottom))
                .overlay(face.strokeBorder(Self.faceHighlight, lineWidth: s / 137))
                .frame(width: 0.883 * s, height: 0.825 * s)
                .offset(x: 0.058 * s, y: 0.032 * s)
            Text("ES")
                .font(.system(size: 0.437 * s, weight: .heavy))
                .kerning(-0.0073 * s)
                .position(x: 0.5 * s, y: 0.473 * s)
            // Below 32 points the ⌘ shrinks to a speck, so Finder's 16 and 32 point sizes leave it out.
            if s >= 32 {
                Text("⌘")
                    .font(.system(size: 0.143 * s, weight: .semibold))
                    .opacity(0.72)
                    .position(x: 0.813 * s, y: 0.146 * s)
            }
        }
        .foregroundStyle(Color(nsColor: BadgeStyle.text))
        .frame(width: s, height: s)
        .background(LinearGradient(colors: [Self.keycapTop, Self.keycapBottom], startPoint: .top, endPoint: .bottom), in: keycap)
        .overlay(keycap.strokeBorder(Self.keycapBorder, lineWidth: max(1, s / 51)))
    }

    private static let keycapTop = Color(red: 0.90, green: 0.65, blue: 0.20)
    private static let keycapBottom = Color(red: 0.70, green: 0.48, blue: 0.09)
    private static let keycapBorder = Color(red: 0.54, green: 0.37, blue: 0.08)
    private static let faceHighlight = Color(red: 1.0, green: 0.98, blue: 0.79).opacity(0.7)
}
