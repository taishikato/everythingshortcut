import AppKit

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
