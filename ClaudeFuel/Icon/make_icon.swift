import AppKit

// Usage: swift make_icon.swift <source.png> <out.iconset dir>
// Renders each required icon size with the native macOS rounded-rect mask.
let args = CommandLine.arguments
guard args.count >= 3, let img = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("make_icon: bad args or unreadable source\n".data(using: .utf8)!); exit(1)
}
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]

for (name, px) in sizes {
    let out = NSImage(size: NSSize(width: px, height: px))
    out.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let r = CGFloat(px) * 0.2237                       // Apple squircle-ish corner radius
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).addClip()
    img.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
    out.unlockFocus()
    guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
