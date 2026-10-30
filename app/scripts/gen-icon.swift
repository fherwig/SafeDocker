// Safe's app icon: a ship's porthole with eight bolts and a keyhole in the glass,
// white on a navy squircle, in the design language of Marina's icon (the same
// squircle, margin, gradient and line weights).
//
//   swift gen-icon.swift OUTPUT.png      renders the 1024 x 1024 master
//
// make-icon.sh turns the master into Resources/Safe.icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "safe-icon.png"
let size: CGFloat = 1024
let c = NSPoint(x: size / 2, y: size / 2)
let sea = NSColor(calibratedRed: 0.07, green: 0.30, blue: 0.52, alpha: 1)

func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
}

func ring(radius: CGFloat, lineWidth: CGFloat) {
    let p = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                        width: 2 * radius, height: 2 * radius))
    p.lineWidth = lineWidth
    p.stroke()
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon squircle with the standard ~100px transparent margin
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
NSGraphicsContext.current?.saveGraphicsState()
NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185).addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.34, alpha: 1),  // deep sea
    NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.70, alpha: 1)   // harbour blue
])?.draw(in: rect, angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

NSColor.white.setStroke()
NSColor.white.setFill()

// the porthole: a broad brass ring with a thin inner companion, like the wheel's rim
ring(radius: 300, lineWidth: 56)
ring(radius: 232, lineWidth: 14)

// eight bolts in the ring, sea blue, between the wheel's eight spoke positions
sea.setFill()
for i in 0..<8 {
    let a = CGFloat(i) * .pi / 4 + .pi / 8
    disc(c.x + cos(a) * 300, c.y + sin(a) * 300, 16)
}

// the keyhole in the glass
NSColor.white.setFill()
let s: CGFloat = 150
disc(c.x, c.y + 0.35 * s, 0.42 * s)
let slot = NSBezierPath()
slot.move(to: NSPoint(x: c.x - 0.2 * s, y: c.y + 0.3 * s))
slot.line(to: NSPoint(x: c.x + 0.2 * s, y: c.y + 0.3 * s))
slot.line(to: NSPoint(x: c.x + 0.32 * s, y: c.y - 0.75 * s))
slot.line(to: NSPoint(x: c.x - 0.32 * s, y: c.y - 0.75 * s))
slot.close()
slot.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
