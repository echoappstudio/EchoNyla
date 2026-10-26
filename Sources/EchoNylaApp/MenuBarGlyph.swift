import AppKit

/// The menu-bar picture, matching the app icon: a page outline with a chevron over a solid tray.
/// A template image, so macOS colours it for light and dark menu bars.
enum MenuBarGlyph {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // The page, with its top-right corner folded.
            let page = NSBezierPath()
            page.move(to: NSPoint(x: 6.2, y: 2.2))
            page.line(to: NSPoint(x: 10.6, y: 2.2))
            page.line(to: NSPoint(x: 13.2, y: 4.8))
            page.line(to: NSPoint(x: 13.2, y: 10.4))
            page.move(to: NSPoint(x: 6.2, y: 2.2))
            page.line(to: NSPoint(x: 6.2, y: 10.4))
            page.lineWidth = 1.3
            page.lineJoinStyle = .round
            page.stroke()

            // The chevron on the page.
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 8.1, y: 6.0))
            chevron.line(to: NSPoint(x: 9.7, y: 7.6))
            chevron.line(to: NSPoint(x: 11.3, y: 6.0))
            chevron.lineWidth = 1.4
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()

            // The tray in front: a solid shape with a notch where the page goes in.
            let tray = NSBezierPath()
            tray.move(to: NSPoint(x: 1.8, y: 10.0))
            tray.line(to: NSPoint(x: 5.2, y: 10.0))
            tray.line(to: NSPoint(x: 6.2, y: 11.9))
            tray.line(to: NSPoint(x: 13.2, y: 11.9))
            tray.line(to: NSPoint(x: 14.2, y: 10.0))
            tray.line(to: NSPoint(x: 17.6, y: 10.0))
            tray.line(to: NSPoint(x: 17.6, y: 14.2))
            tray.appendArc(withCenter: NSPoint(x: 15.2, y: 14.2), radius: 2.4, startAngle: 0, endAngle: 90, clockwise: false)
            tray.line(to: NSPoint(x: 4.2, y: 16.6))
            tray.appendArc(withCenter: NSPoint(x: 4.2, y: 14.2), radius: 2.4, startAngle: 90, endAngle: 180, clockwise: false)
            tray.close()
            tray.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "EchoNyla"
        return image
    }
}
