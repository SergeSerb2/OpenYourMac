import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("svg2png: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4,
      let size = Int(CommandLine.arguments[3]), size > 0 else {
    fail("usage: swift scripts/svg2png.swift <input.svg> <output.png> <size>")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: input) else {
    fail("cannot load \(input.path)")
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("cannot create a \(size) × \(size) image")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("cannot encode PNG data")
}
do {
    try png.write(to: output, options: .atomic)
} catch {
    fail("cannot write \(output.path): \(error.localizedDescription)")
}
