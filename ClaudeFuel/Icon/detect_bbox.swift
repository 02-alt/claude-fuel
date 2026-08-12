import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let w = rep.pixelsWide, h = rep.pixelsHigh
func brightCount(col x: Int) -> Int { var n=0; for y in stride(from:0,to:h,by:3){ if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), c.brightnessComponent>0.30 {n+=1} }; return n }
func brightCountRow(_ y: Int) -> Int { var n=0; for x in stride(from:0,to:w,by:3){ if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), c.brightnessComponent>0.30 {n+=1} }; return n }
// require at least ~30 bright samples in a line to count as "device", ignoring stray pixels
let thr = 30
var minX=0; for x in 0..<w { if brightCount(col:x) > thr { minX=x; break } }
var maxX=w-1; for x in stride(from:w-1,through:0,by:-1) { if brightCount(col:x) > thr { maxX=x; break } }
var minY=0; for y in 0..<h { if brightCountRow(y) > thr { minY=y; break } }
var maxY=h-1; for y in stride(from:h-1,through:0,by:-1) { if brightCountRow(y) > thr { maxY=y; break } }
print("device bbox: x \(minX)..\(maxX)  y \(minY)..\(maxY)")
print("margins L=\(minX) R=\(w-1-maxX) T=\(minY) B=\(h-1-maxY)  size=\(w)x\(h)")
