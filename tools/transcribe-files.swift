#!/usr/bin/env swift

//  Transcrit les fichiers audio passés en argument et rend du JSON sur la sortie
//  standard. Contrairement à transcribe.swift, qui parcourt le manifest leçon par
//  leçon, celui-ci ne connaît rien du corpus : on lui donne des chemins, il rend du
//  texte. C'est ce qui permet de lui soumettre un clip transformé — ralenti, par
//  exemple — sans rien changer aux données du projet.
//
//  Comme transcribe.swift, il stocke des faits (texte, confiance, durée) et ne les
//  interprète pas : l'interprétation vit côté Python, où elle se recalibre sans
//  relancer la reconnaissance.
//
//      swift tools/transcribe-files.swift a.m4a b.m4a  > out.json

import Foundation
import Speech
import AVFoundation

struct Result: Codable {
    let path: String
    let text: String
    let confidence: Double
    let duration: Double
    let error: String?
}

let locale = Locale(identifier: "es-ES")

func installModelIfNeeded() async throws {
    let probe = SpeechTranscriber(locale: locale, preset: .transcription)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
    else { return }
    try await request.downloadAndInstall()
}

func transcribe(_ url: URL) async throws -> (String, Double, Double) {
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber],
                                  options: .init(priority: .medium,
                                                 modelRetention: .processLifetime))
    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
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
    return (text.trimmingCharacters(in: .whitespacesAndNewlines), worst, duration)
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage : swift tools/transcribe-files.swift <audio…>\n".utf8))
    exit(2)
}

@MainActor func run() async {
    do { try await installModelIfNeeded() } catch {
        FileHandle.standardError.write(Data("Modèle es-ES indisponible : \(error)\n".utf8))
        exit(1)
    }

    var results: [Result] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        do {
            let (text, confidence, duration) = try await transcribe(url)
            results.append(Result(path: path, text: text, confidence: confidence,
                                  duration: duration, error: nil))
        } catch {
            results.append(Result(path: path, text: "", confidence: 0, duration: 0,
                                  error: "\(error)"))
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    if let data = try? encoder.encode(results) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

await run()
