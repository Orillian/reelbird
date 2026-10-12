// Renders an SVG to a PNG with the system's own SVG renderer (AppKit/CoreSVG),
// so brand assets build on any Mac with only the Command Line Tools.
//
//   swiftc -O brand/tools/render-svg.swift -o /tmp/render-svg
//   /tmp/render-svg <in.svg> <out.png> <width> [height]
//
// Height defaults to the SVG's aspect ratio. Output is sRGB with alpha.
// CoreSVG supports gradients, clip paths and feGaussianBlur but not feMerge,
// feFlood or feComposite, so the brand SVGs draw shadows as blurred copies.
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let width = Int(args[3]), width > 0 else {
    fputs("usage: render-svg <in.svg> <out.png> <width> [height]\n", stderr)
    exit(64)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])), image.size.width > 0 else {
    fputs("render-svg: cannot read \(args[1])\n", stderr)
    exit(66)
}
let height = args.count > 4 ? (Int(args[4]) ?? width) : Int((Double(width) * image.size.height / image.size.width).rounded())

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("render-svg: cannot create bitmap context\n", stderr)
    exit(70)
}
context.interpolationQuality = .high
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil) else {
    fputs("render-svg: cannot write \(args[2])\n", stderr)
    exit(73)
}
CGImageDestinationAddImage(destination, rendered, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 73)
