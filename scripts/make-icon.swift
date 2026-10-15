//  Draws Resources/AppIcon.icns from PortGlyph, so the repository carries no
//  binary icon and the icon can be restyled by editing numbers.
//
//  Usage: make icon
//  (Compiled together with Sources/PortGlyph.swift — hence @main, since
//  top-level code is only allowed in a file called main.swift.)

import AppKit
import Foundation

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "make-icon", code: 1) }
    try data.write(to: url)
}

@main
struct MakeIcon {
    static func main() throws {
        let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

        let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portbuddy-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        let variants: [(name: String, size: CGFloat)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        for variant in variants {
            try writePNG(PortGlyph.appIcon(size: variant.size), to: iconset.appendingPathComponent(variant.name))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("iconutil failed\n".utf8))
            exit(1)
        }
        print("wrote \(outputPath)")
    }
}
