//  The one mark this app uses: a socket with two contacts leaving to the
//  right. Drawn from the same numbers at any size, so the menu bar icon and
//  the app icon are the same shape.

import AppKit

enum PortGlyph {
    /// Paints the mark into `rect` with the caller's stroke and fill colours,
    /// so it can be a black template in the menu bar and white-and-green on
    /// the app icon.
    static func draw(in rect: NSRect) {
        let s = rect.width

        let socket = NSBezierPath(roundedRect: NSRect(x: rect.minX + s * 0.10,
                                                      y: rect.minY + s * 0.22,
                                                      width: s * 0.46,
                                                      height: s * 0.56),
                                  xRadius: s * 0.11, yRadius: s * 0.11)
        socket.lineWidth = s * 0.085
        socket.stroke()

        NSBezierPath(roundedRect: NSRect(x: rect.minX + s * 0.58,
                                         y: rect.minY + s * 0.42,
                                         width: s * 0.30,
                                         height: s * 0.16),
                     xRadius: s * 0.08, yRadius: s * 0.08).fill()
    }

    /// Menu bar icon. Template, so macOS paints it white or black to match.
    static func statusImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// App icon: dark rounded square, white socket, green contacts.
    static func appIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let full = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: full, xRadius: size * 0.2237, yRadius: size * 0.2237).addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.19, blue: 0.25, alpha: 1),
                            NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1)])?.draw(in: full, angle: -90)
        let boxSide = size * 0.52
        NSColor.white.setStroke()
        NSColor.systemGreen.setFill()
        draw(in: NSRect(x: (size - boxSide) / 2, y: (size - boxSide) / 2, width: boxSide, height: boxSide))
        image.unlockFocus()
        return image
    }
}
