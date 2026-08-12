import AppKit
// crop.swift <src> <centerX> <centerY> <side> <out>
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let cg = rep.cgImage!
let cx = Double(a[2])!, cy = Double(a[3])!, side = Double(a[4])!
let rect = CGRect(x: cx - side/2, y: cy - side/2, width: side, height: side)
let cropped = cg.cropping(to: rect)!
let out = NSBitmapImageRep(cgImage: cropped)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[5]))
print("cropped \(cropped.width)x\(cropped.height)")
