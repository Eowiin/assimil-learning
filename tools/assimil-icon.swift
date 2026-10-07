import AppKit
import CoreGraphics
import CoreText

// Usage : swift tools/assimil-icon.swift <icône Assimil 1024 px> <dossier de sortie>
//
// L'icône de départ est celle de l'app Assimil sur l'App Store (1024 × 1024) ; le
// résultat va dans AssimilES/Assets.xcassets/AppIconAssimil.appiconset/, hors dépôt.
//
// Deux variantes locales de l'icône Assimil pour l'espagnol :
//  diagonale — la zone blanche sous le logo devient le drapeau, bandes parallèles à
//              la coupure du logo (comme les couvertures Assimil) ;
//  badge     — un drapeau 3:2 ondulé, avec reflet, dans le coin blanc.
let input = CommandLine.arguments[1], outDir = CommandLine.arguments[2]
let W = 1024, H = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Couleurs officielles du drapeau espagnol.
let rojo: (Double, Double, Double) = (0xAA / 255.0, 0x15 / 255.0, 0x1B / 255.0)
let gualda: (Double, Double, Double) = (0xF1 / 255.0, 0xBF / 255.0, 0x00 / 255.0)

func loadPixels() -> [UInt8] {
    let src = NSImage(contentsOfFile: input)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    var px = [UInt8](repeating: 0, count: W * H * 4)
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: W, height: H))
    return px  // rangée 0 = haut de l'image
}

func save(_ px: [UInt8], _ name: String) {
    var data = px
    let ctx = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print(name)
}

/// Blancheur d'un pixel : 1 pour un blanc pur, 0 dès qu'il a de la couleur ou de l'ombre.
func whiteness(_ px: [UInt8], _ i: Int) -> Double {
    let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
    let mn = min(r, g, b), mx = max(r, g, b)
    let light = max(0, (mn - 150) / 105)          // 150 → 0, 255 → 1
    let gray = max(0, 1 - (mx - mn) / 60)          // désaturé
    return min(1, light * gray)
}

// MARK: - Variante diagonale

do {
    var px = loadPixels()
    // La zone blanche reliée au coin bas-droit (remplissage par diffusion) : les lettres,
    // cernées de bleu, n'y sont pas reliées.
    var region = [Bool](repeating: false, count: W * H)
    var stack = [(W - 1, H - 1)]
    while let (x, y) = stack.popLast() {
        guard x >= 0, y >= 0, x < W, y < H, !region[y * W + x] else { continue }
        guard whiteness(px, (y * W + x) * 4) > 0.55 else { continue }
        region[y * W + x] = true
        stack.append((x + 1, y)); stack.append((x - 1, y)); stack.append((x, y + 1)); stack.append((x, y - 1))
    }
    // La coupure : pour chaque colonne, le pixel le plus haut de la zone ; droite ajustée.
    var xs: [Double] = [], ys: [Double] = []
    for x in stride(from: 40, to: W - 40, by: 8) {
        if let y = (0..<H).first(where: { region[$0 * W + x] }), y > 0 { xs.append(Double(x)); ys.append(Double(y)) }
    }
    let n = Double(xs.count)
    let mx: Double = xs.reduce(0.0, +) / n
    let my: Double = ys.reduce(0.0, +) / n
    var sxy = 0.0, sxx = 0.0
    for k in xs.indices {
        let dx: Double = xs[k] - mx
        sxy += dx * (ys[k] - my)
        sxx += dx * dx
    }
    let slope: Double = sxy / sxx
    // Distance perpendiculaire à la coupure, positive vers le coin bas-droit (y vers le bas).
    let norm: Double = (1.0 + slope * slope).squareRoot()
    func dist(_ x: Double, _ y: Double) -> Double { ((y - my) - slope * (x - mx)) / norm }
    // Les bandes couvrent l'étendue réelle de la zone, pas le coin de l'image.
    var dmin = Double.infinity, dmax = -Double.infinity
    for y in 0..<H { for x in 0..<W where region[y * W + x] {
        let d = dist(Double(x), Double(y)); dmin = min(dmin, d); dmax = max(dmax, d)
    } }
    // La virgule rouge du logo disparaît sous le drapeau : elle y faisait tache. On
    // recouvre la virgule et son bord lissé, sans toucher au bleu ni aux lettres.
    let original = px
    func isSwoosh(_ x: Int, _ y: Int) -> Bool {
        let i = (y * W + x) * 4
        return original[i] > 150 && original[i + 1] < 90 && original[i + 2] < 90
    }
    var halo = [Bool](repeating: false, count: W * H)
    let r = 9
    for y in 0..<H { for x in 0..<W where isSwoosh(x, y) {
        for dy in -r...r { for dx in -r...r where dx * dx + dy * dy <= r * r {
            let xx = x + dx, yy = y + dy
            if xx >= 0, yy >= 0, xx < W, yy < H { halo[yy * W + xx] = true }
        } }
    } }
    // Bandes 1 : 2 : 1, parallèles à la coupure.
    for y in 0..<H {
        for x in 0..<W {
            let idx = y * W + x, i = idx * 4
            // Le bord lissé : un pixel clair voisin de la zone en fait partie à proportion.
            var a = region[idx] ? 1.0 : 0.0
            if a == 0 {
                let neighbours = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
                if neighbours.contains(where: { $0.0 >= 0 && $0.1 >= 0 && $0.0 < W && $0.1 < H && region[$0.1 * W + $0.0] }) {
                    a = whiteness(px, i)
                }
            }
            if halo[idx] {
                let r0 = Double(original[i]), b0 = Double(original[i + 2])
                if b0 < r0 + 40 { a = 1 }   // pas du bleu : virgule ou blanc autour
            }
            guard a > 0 else { continue }
            let t = (dist(Double(x), Double(y)) - dmin) / (dmax - dmin)
            let c = (t < 0.25 || t > 0.75) ? rojo : gualda
            px[i] = UInt8(Double(px[i]) * (1 - a) + c.0 * 255 * a)
            px[i + 1] = UInt8(Double(px[i + 1]) * (1 - a) + c.1 * 255 * a)
            px[i + 2] = UInt8(Double(px[i + 2]) * (1 - a) + c.2 * 255 * a)
        }
    }
    save(px, "assimil-espana-diagonale.png")
}

// MARK: - Variante badge

do {
    var px = loadPixels()
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Repère CoreGraphics : origine en bas à gauche.
    let flagW = 420.0, flagH = 280.0, x0 = 560.0, y0 = 70.0
    let amp = 14.0
    func wave(_ u: Double) -> Double { amp * sin(u * 2 * .pi * 1.0 + 0.6) }
    // Ombre portée
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 34, color: CGColor(gray: 0, alpha: 0.3))
    let outline = CGMutablePath()
    let steps = 80
    for k in 0...steps { let u = Double(k) / Double(steps); let p = CGPoint(x: x0 + u * flagW, y: y0 + wave(u))
        k == 0 ? outline.move(to: p) : outline.addLine(to: p) }
    for k in stride(from: steps, through: 0, by: -1) { let u = Double(k) / Double(steps)
        outline.addLine(to: CGPoint(x: x0 + u * flagW, y: y0 + flagH + wave(u))) }
    outline.closeSubpath()
    ctx.addPath(outline); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // Bandes 1 : 2 : 1 et ombrage de l'ondulation, en fines tranches verticales.
    for k in 0..<steps {
        let u0 = Double(k) / Double(steps), u1 = Double(k + 1) / Double(steps)
        let shade = 0.82 + 0.18 * cos(u0 * 2 * .pi + 0.6)   // creux plus sombres, crêtes plus claires
        for (from, to, c) in [(0.0, 0.25, rojo), (0.25, 0.75, gualda), (0.75, 1.0, rojo)] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x0 + u0 * flagW, y: y0 + wave(u0) + from * flagH))
            p.addLine(to: CGPoint(x: x0 + u1 * flagW + 0.6, y: y0 + wave(u1) + from * flagH))
            p.addLine(to: CGPoint(x: x0 + u1 * flagW + 0.6, y: y0 + wave(u1) + to * flagH))
            p.addLine(to: CGPoint(x: x0 + u0 * flagW, y: y0 + wave(u0) + to * flagH))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(CGColor(srgbRed: c.0 * shade, green: c.1 * shade, blue: c.2 * shade, alpha: 1))
            ctx.fillPath()
        }
    }
    // Reflet doux sur la moitié haute.
    ctx.saveGState(); ctx.addPath(outline); ctx.clip()
    let gloss = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: y0 + flagH + amp), end: CGPoint(x: 0, y: y0 + flagH * 0.45), options: [])
    ctx.restoreGState()
    // Liseré
    ctx.addPath(outline); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); ctx.setLineWidth(3); ctx.strokePath()
    save(px, "assimil-espana-badge.png")
}
