import AppKit
import Badge
import SwiftUI

/// The app icon as an `.iconset` for `iconutil`. Each size draws the badge 824 points wide on Apple's
/// 1024-point icon grid, scaled down to that size, so `AppIcon` decides what a small size leaves out.
enum IconSet {
    struct RenderFailed: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            let side = CGFloat(points)
            let renderer = ImageRenderer(content: AppIcon(size: side * 824 / 1024).frame(width: side, height: side))
            for scale in [1, 2] {
                renderer.scale = CGFloat(scale)
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { throw RenderFailed(description: "could not render \(name)") }
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
