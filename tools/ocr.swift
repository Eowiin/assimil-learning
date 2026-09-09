#!/usr/bin/env swift
//
// OCR local des pages du livre Assimil, via le framework Vision d'Apple.
// Gratuit, hors ligne, et nettement meilleur que les OCR génériques sur de l'imprimé.
//
//   swift tools/ocr.swift scans/L001.pdf scans/L002.pdf ...
//   swift tools/ocr.swift --lang es-ES scans/*.png
//
// Écrit un JSON par fichier dans content/ocr/, contenant chaque ligne reconnue avec
// sa position. Les positions sont indispensables : une page Assimil est en colonnes
// (numéro | phrase espagnole | prononciation figurée) et l'ordre de lecture brut
// mélange tout. C'est l'étape de structuration qui s'en sert pour recomposer.
//
// Les coordonnées sont normalisées 0-1, origine en HAUT à gauche (Vision les fournit
// en bas à gauche ; converties ici pour correspondre à la lecture humaine).

import Foundation
import Vision
import AppKit
import PDFKit

struct Line: Codable {
    let text: String
    let confidence: Float
    let x: Double      // bord gauche
    let y: Double      // bord haut, 0 = haut de page
    let width: Double
    let height: Double
}

struct Page: Codable {
    let index: Int
    let lines: [Line]
}

struct Document: Codable {
    let source: String
    let languages: [String]
    let pages: [Page]
}

// MARK: - Arguments

var languages = ["es-ES", "fr-FR"]
var inputs: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    if arg == "--lang" {
        guard let value = args.first else {
            FileHandle.standardError.write(Data("--lang attend une valeur\n".utf8))
            exit(2)
        }
        args.removeFirst()
        languages = value.split(separator: ",").map(String.init)
    } else {
        inputs.append(arg)
    }
}

guard !inputs.isEmpty else {
    print("usage: swift tools/ocr.swift [--lang es-ES,fr-FR] <fichiers pdf|png|jpg>")
    exit(2)
}

// MARK: - Rendu des pages

/// Un scan de l'app Notes arrive en PDF, une photo en image : les deux sont ramenés
/// à une liste de bitmaps.
func images(at path: String) -> [CGImage] {
    let url = URL(fileURLWithPath: path)

    if url.pathExtension.lowercased() == "pdf" {
        guard let pdf = PDFDocument(url: url) else { return [] }
        return (0..<pdf.pageCount).compactMap { i -> CGImage? in
            guard let page = pdf.page(at: i) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            // 300 dpi : en dessous, la prononciation figurée en petits caractères
            // et les appels de notes en exposant se dégradent nettement.
            let scale = 300.0 / 72.0
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .mediaBox, to: ctx)
            }
            image.unlockFocus()
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return [] }
    return [cg]
}

// MARK: - Reconnaissance

/// Fait tourner l'image d'un quart de tour ou d'un demi-tour.
func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
    guard degrees != 0 else { return image }
    let radians = CGFloat(degrees) * .pi / 180
    let quarterTurn = degrees % 180 != 0
    let width = quarterTurn ? image.height : image.width
    let height = quarterTurn ? image.width : image.height

    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    context.rotate(by: radians)
    context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
}

/// Inclinaison médiane du texte, en degrés.
///
/// Vision lit correctement une page photographiée de travers, mais rend des
/// coordonnées dans le repère de l'image : une page prise à 90° voit ses deux
/// colonnes se mélanger. L'angle des lignes reconnues permet de le détecter.
func medianTextAngle(_ observations: [VNRecognizedTextObservation],
                     width: Int, height: Int) -> Double {
    let angles = observations.map { observation -> Double in
        // Les coordonnées sont normalisées : il faut les remettre à l'échelle
        // de l'image, sinon l'angle est déformé par le rapport d'aspect.
        let dx = Double(observation.topRight.x - observation.topLeft.x) * Double(width)
        let dy = Double(observation.topRight.y - observation.topLeft.y) * Double(height)
        return atan2(dy, dx) * 180 / .pi
    }
    guard !angles.isEmpty else { return 0 }
    return angles.sorted()[angles.count / 2]
}

func detect(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return request.results ?? []
}

func recognize(_ image: CGImage) throws -> [Line] {
    var image = image
    var observations = try detect(image)

    // Si le texte n'est pas horizontal, on redresse l'image et on relit : c'est
    // plus fiable que de tenter de faire pivoter les coordonnées après coup.
    let angle = medianTextAngle(observations, width: image.width, height: image.height)
    let quarterTurns = Int((angle / 90).rounded())
    if quarterTurns != 0, let straightened = rotate(image, degrees: -quarterTurns * 90) {
        let corrected = try detect(straightened)
        if !corrected.isEmpty {
            let residual = medianTextAngle(corrected, width: straightened.width, height: straightened.height)
            if abs(residual) < abs(angle) {
                FileHandle.standardError.write(
                    Data("  page redressée de \(-quarterTurns * 90)°\n".utf8))
                image = straightened
                observations = corrected
            }
        }
    }

    return observations.compactMap { observation -> Line? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return Line(
            text: candidate.string,
            confidence: candidate.confidence,
            x: Double(box.minX),
            y: Double(1 - box.maxY),   // origine ramenée en haut
            width: Double(box.width),
            height: Double(box.height)
        )
    }
    // Ordre de lecture approximatif : de haut en bas, puis de gauche à droite.
    // La séparation réelle des colonnes se fait à l'étape de structuration.
    .sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
}

// MARK: - Exécution

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("content/ocr")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

var failed = false
for path in inputs {
    let pages = images(at: path)
    guard !pages.isEmpty else {
        FileHandle.standardError.write(Data("illisible : \(path)\n".utf8))
        failed = true
        continue
    }

    do {
        let recognized = try pages.enumerated().map { Page(index: $0.offset, lines: try recognize($0.element)) }
        let document = Document(source: path, languages: languages, pages: recognized)

        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let out = outputDir.appendingPathComponent("\(name).json")
        try encoder.encode(document).write(to: out)

        let lineCount = recognized.reduce(0) { $0 + $1.lines.count }
        let weak = recognized.flatMap(\.lines).filter { $0.confidence < 0.5 }.count
        print("\(name) : \(recognized.count) page(s), \(lineCount) lignes, \(weak) peu fiables → content/ocr/\(name).json")
    } catch {
        FileHandle.standardError.write(Data("échec sur \(path) : \(error)\n".utf8))
        failed = true
    }
}

exit(failed ? 1 : 0)
