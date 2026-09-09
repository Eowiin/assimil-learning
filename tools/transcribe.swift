#!/usr/bin/env swift
//
// Transcription locale de l'audio Assimil, via le framework Speech de macOS 26.
// Gratuit, hors ligne, et rien ne sort de la machine — l'ancienne API
// SFSpeechRecognizer aurait envoyé l'audio aux serveurs d'Apple faute de modèle
// espagnol installé sur cette machine ; SpeechTranscriber installe le modèle et
// travaille en local.
//
//   swift tools/transcribe.swift              # les 100 leçons, incrémental
//   swift tools/transcribe.swift L006 L007    # seulement celles-là
//   swift tools/transcribe.swift --force L002 # refait même si déjà transcrit
//
// Écrit un JSON par leçon dans content/asr/.
//
// Pourquoi ça marche si bien ici : la source est découpée phrase par phrase, donc
// chaque fichier contient une réplique et une seule. Il n'y a aucun alignement à
// faire — le numéro du fichier EST le numéro de la phrase. C'est ce qui permet
// d'obtenir le texte espagnol des 100 leçons sans scanner le livre.
//
// Ce que ça ne donne pas : la traduction française, la prononciation figurée et les
// notes, qui n'existent que dans le livre.

import Foundation
import Speech
import AVFoundation

// MARK: - Entrées / sorties

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                                          .deletingLastPathComponent()
let audioDir = root.appendingPathComponent("Resources/audio")
let outDir = root.appendingPathComponent("content/asr")
let manifestURL = root.appendingPathComponent("Resources/manifest.json")

struct Clip: Codable {
    let file: String
    let duration: Double
    let n: Int?
}

struct ManifestLesson: Codable {
    let number: Int
    let isReview: Bool
    let dir: String
    let title: Clip?
    let dialogue: [Clip]
    let exercise: [Clip]
}

struct Manifest: Codable {
    let lessons: [ManifestLesson]
}

struct Recognized: Codable {
    let n: Int?
    let file: String
    let es: String
    let confidence: Double
    let duration: Double
    let flag: String?
}

struct LessonASR: Codable {
    let number: Int
    let locale: String
    let title: Recognized?
    let dialogue: [Recognized]
    let exercise: [Recognized]
    let flagged: [String]
}

// MARK: - Arguments

var force = false
var wanted: Set<String> = []
for arg in CommandLine.arguments.dropFirst() {
    if arg == "--force" { force = true } else { wanted.insert(arg) }
}

guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
    FileHandle.standardError.write(Data(
        "Resources/manifest.json illisible — lancer build-manifest.py d'abord\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Orthographe

/// L'espagnol ouvre ses interrogations et exclamations. La reconnaissance vocale
/// restitue bien la ponctuation finale mais oublie l'ouvrante : « Y vives en
/// Barcelona? » pour « ¿Y vives en Barcelona? ». La règle est mécanique, donc sûre.
func restoreOpeners(_ text: String) -> String {
    var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for (closer, opener) in [("?", "¿"), ("!", "¡")] {
        guard out.hasSuffix(closer), !out.contains(opener) else { continue }
        // L'ouvrante se place au début de la proposition interrogative, qui suit la
        // dernière virgule quand la phrase en compte une (« Y el francés, ¿lo habla? »).
        if let comma = out.lastIndex(of: ",") {
            let after = out.index(after: comma)
            let head = out[..<after]
            let tail = out[after...].drop(while: { $0 == " " })
            out = "\(head) \(opener)\(tail)"
        } else {
            out = opener + out
        }
    }
    return out
}

// MARK: - Transcription

let locale = Locale(identifier: "es-ES")

func installModelIfNeeded() async throws {
    let installed = await SpeechTranscriber.installedLocales.contains {
        $0.identifier(.bcp47) == locale.identifier(.bcp47)
    }
    let probe = SpeechTranscriber(locale: locale, preset: .transcription)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
    else { return }
    if !installed {
        FileHandle.standardError.write(Data("Installation du modèle es-ES…\n".utf8))
    }
    try await request.downloadAndInstall()
}

func transcribe(_ url: URL) async throws -> (String, Double) {
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    // Le modèle reste chargé d'un fichier à l'autre : sans cela, chaque appel le
    // rechargerait et les 1899 clips prendraient des heures.
    let analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .medium,
                                                 modelRetention: .processLifetime))
    let file = try AVAudioFile(forReading: url)
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    var text = ""
    var worst = 1.0
    for try await result in transcriber.results {
        text += String(result.text.characters)
        for run in result.text.runs {
            if let c = run.transcriptionConfidence { worst = min(worst, Double(c)) }
        }
    }
    return (restoreOpeners(text), worst)
}

/// Seuls les échecs francs sont marqués ici. Le repérage des répliques suspectes
/// (celles dont l'audio dure plus longtemps que le texte ne l'explique) est laissé à
/// asr-to-text.py : la transcription coûte trois minutes, l'interprétation rien, et
/// recalibrer un seuil ne doit pas obliger à tout refaire.
func flag(text: String) -> String? {
    text.isEmpty ? "aucun texte reconnu" : nil
}

@MainActor func run() async {
    do { try await installModelIfNeeded() } catch {
        FileHandle.standardError.write(Data("Installation du modèle impossible : \(error)\n".utf8))
        exit(1)
    }

    for lesson in manifest.lessons {
        let name = String(format: "L%03d", lesson.number)
        if !wanted.isEmpty && !wanted.contains(name) { continue }
        let out = outDir.appendingPathComponent("\(name).json")
        if !force, FileManager.default.fileExists(atPath: out.path) {
            print("\(name) : déjà transcrit")
            continue
        }
        let dir = audioDir.appendingPathComponent(lesson.dir)

        func recognize(_ clip: Clip) async -> Recognized {
            let url = dir.appendingPathComponent(clip.file)
            do {
                let (text, confidence) = try await transcribe(url)
                return Recognized(n: clip.n, file: clip.file, es: text,
                                  confidence: confidence, duration: clip.duration,
                                  flag: flag(text: text))
            } catch {
                return Recognized(n: clip.n, file: clip.file, es: "", confidence: 0,
                                  duration: clip.duration, flag: "échec : \(error.localizedDescription)")
            }
        }

        var title: Recognized?
        if let t = lesson.title { title = await recognize(t) }
        var dialogue: [Recognized] = []
        for clip in lesson.dialogue { dialogue.append(await recognize(clip)) }
        var exercise: [Recognized] = []
        for clip in lesson.exercise { exercise.append(await recognize(clip)) }

        let flagged = (dialogue + exercise + (title.map { [$0] } ?? []))
            .compactMap { r in r.flag.map { "\(r.file) : \($0)" } }
        let asr = LessonASR(number: lesson.number, locale: locale.identifier,
                            title: title, dialogue: dialogue, exercise: exercise,
                            flagged: flagged)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let data = try? encoder.encode(asr) { try? data.write(to: out) }

        print("\(name) : \(dialogue.count) répliques, \(exercise.count) exercice"
              + (flagged.isEmpty ? "" : "  ⚠ \(flagged.count) à vérifier"))
    }
    print("→ content/asr/")
}

await run()
