import AppKit
import CoreGraphics
import CoreText

// Usage : swift tools/make-icon.swift AssimilES/Assets.xcassets/AppIcon.appiconset
//
// Icône AssimilES : un « n » blanc dont le tilde est une onde jaune — la lettre de
// l'espagnol, et la voix. Trois variantes : claire, sombre, teintée (iOS 18+).
let size = 1024.0
let out = CommandLine.arguments[1]

enum Variant: String { case light, dark, tinted }

func render(_ variant: Variant) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Fond
    switch variant {
    case .light:
        let g = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.27, green: 0.40, blue: 0.95, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.24, blue: 0.70, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    case .dark:
        let g = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.13, green: 0.16, blue: 0.30, alpha: 1),
            CGColor(srgbRed: 0.05, green: 0.06, blue: 0.12, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    case .tinted:
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(rect)
    }

    let letterColor: CGColor = variant == .tinted ? CGColor(gray: 0.92, alpha: 1)
        : variant == .dark ? CGColor(srgbRed: 0.62, green: 0.71, blue: 1, alpha: 1)
        : CGColor(gray: 1, alpha: 1)
    let waveColor: CGColor = variant == .tinted ? CGColor(gray: 0.62, alpha: 1)
        : CGColor(srgbRed: 1, green: 0.80, blue: 0.28, alpha: 1)

    // Le « n » : SF Rounded Heavy, centré un peu bas pour laisser l'onde au-dessus.
    let font = NSFont.systemFont(ofSize: 620, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 620) } ?? font
    let attrs: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: NSColor(cgColor: letterColor)!]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "n", attributes: attrs))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let x = (size - bounds.width) / 2 - bounds.minX
    let y = size * 0.25 - bounds.minY
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)

    // Le tilde : une onde, au-dessus de la lettre, de la largeur du « n ».
    let top = y + bounds.maxY
    let left = (size - bounds.width) / 2 + 8
    let width = bounds.width - 16
    let mid = top + 118
    let amp = 46.0
    let path = CGMutablePath()
    let steps = 120
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let px = left + t * width
        let py = mid + amp * sin(t * 2 * .pi)
        i == 0 ? path.move(to: CGPoint(x: px, y: py)) : path.addLine(to: CGPoint(x: px, y: py))
    }
    ctx.addPath(path)
    ctx.setStrokeColor(waveColor)
    ctx.setLineWidth(74)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for variant in [Variant.light, .dark, .tinted] {
    let url = URL(fileURLWithPath: out).appendingPathComponent("AppIcon-\(variant.rawValue).png")
    try! render(variant).write(to: url)
    print(url.lastPathComponent)
}
