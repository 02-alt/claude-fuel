import AppKit

// Draws the DMG window background. Minimalist: a plain white canvas with a small
// "buildtoberemembered" signature in the bottom corner. The app icon and the
// Applications alias are placed on top by Finder (see make_dmg.sh).
// NOTE: Finder clips ~28px off the bottom for the title bar, so the signature is
// kept ~60px up from the bottom edge to stay visible.
// Usage: swift make_dmg_bg.swift <out.png>
let out = CommandLine.arguments[1]
let W: CGFloat = 720, H: CGFloat = 480
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// subtle vertical gradient: near-white at the top easing into a soft light grey
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1).cgColor,
    NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// signature in the bottom-right corner (origin is bottom-left, y up)
let f = NSFont.systemFont(ofSize: 14, weight: .medium)
let sig = NSAttributedString(string: "buildtoberemembered",
                             attributes: [.font: f, .foregroundColor: NSColor(white: 0.64, alpha: 1)])
let sz = sig.size()
sig.draw(at: CGPoint(x: W - sz.width - 26, y: 58))

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
