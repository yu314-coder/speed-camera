import AppKit
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("Usage: swift tools/make_icon.swift INPUT_IMAGE OUTPUT_APPICONSET")
}
let input = URL(fileURLWithPath:CommandLine.arguments[1])
let output = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
guard let source = CGImageSourceCreateWithURL(input as CFURL,nil),
      let image = CGImageSourceCreateImageAtIndex(source,0,nil),
      image.width == image.height,
      let space = CGColorSpace(name:CGColorSpace.sRGB),
      let context = CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,
                              space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fail("Cannot read a square source image or create an opaque icon context.")
}
// Apple applies the icon mask; export full-bleed sRGB with no alpha channel.
context.setFillColor(red:0.02,green:0.25,blue:0.26,alpha:1)
context.fill(CGRect(x:0,y:0,width:1024,height:1024))
context.interpolationQuality = .high
context.draw(image,in:CGRect(x:0,y:0,width:1024,height:1024))
guard let rendered = context.makeImage(),
      let png = NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:]) else {
    fail("Cannot encode the app icon.")
}
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
try png.write(to:output.appendingPathComponent("AppIcon.png"),options:.atomic)
let metadata: [String:Any] = ["images":[["filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"]],
                             "info":["author":"xcode","version":1]]
let json = try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys])
try json.write(to:output.appendingPathComponent("Contents.json"),options:.atomic)
print("Exported opaque 1024x1024 sRGB icon: \(output.path)")
