#!/usr/bin/env swift
//
// Banc d'essai du mécanisme de lecture de SessionPlayer, hors app.
//
// Vérifie le point le plus risqué de l'architecture : enchaîner fichier → silence
// → fichier sur un AVAudioPlayerNode, en s'appuyant sur les callbacks
// `.dataPlayedBack` pour avancer. Si l'enchaînement dérive ou se bloque ici, il
// dérivera aussi dans l'app.
//
//   swift tools/audio-smoke-test.swift
//
// Attendu : chaque étape se termine, et la durée mesurée colle à la durée
// annoncée par le manifest (à la latence de sortie près).

import Foundation
import AVFoundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let audio = root.appendingPathComponent("Resources/audio/L001")

let clips = ["S01", "S02", "S03"]
let pauseFactor = 1.3

let engine = AVAudioEngine()
let node = AVAudioPlayerNode()
let timePitch = AVAudioUnitTimePitch()
engine.attach(node)
engine.attach(timePitch)

guard let first = try? AVAudioFile(forReading: audio.appendingPathComponent("S01.m4a")) else {
    print("échec : Resources/audio/L001/S01.m4a introuvable — lancer tools/build-audio.sh")
    exit(1)
}
let format = first.processingFormat
engine.connect(node, to: timePitch, format: format)
engine.connect(timePitch, to: engine.mainMixerNode, format: format)
// Sortie muette : on mesure l'enchaînement, on n'écoute pas.
engine.mainMixerNode.outputVolume = 0
try engine.start()

func silence(_ seconds: Double) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(seconds * format.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        buffer.floatChannelData?[channel].update(repeating: 0, count: Int(frames))
    }
    return buffer
}

struct Step { let label: String; let expected: Double; let file: AVAudioFile? }

var steps: [Step] = []
for name in clips {
    let url = audio.appendingPathComponent("\(name).m4a")
    guard let file = try? AVAudioFile(forReading: url) else {
        print("échec : \(name).m4a illisible")
        exit(1)
    }
    let duration = Double(file.length) / file.processingFormat.sampleRate
    steps.append(Step(label: name, expected: duration, file: file))
    steps.append(Step(label: "pause après \(name)", expected: duration * pauseFactor, file: nil))
}

let done = DispatchSemaphore(value: 0)
var index = 0
var startedAt = Date()
var drift: [Double] = []

func scheduleNext() {
    guard index < steps.count else {
        done.signal()
        return
    }
    let step = steps[index]
    startedAt = Date()

    let completion: (AVAudioPlayerNodeCompletionCallbackType) -> Void = { _ in
        let measured = Date().timeIntervalSince(startedAt)
        let delta = measured - step.expected
        drift.append(delta)
        print(String(format: "  %-22@ attendu %5.2f s   mesuré %5.2f s   écart %+.2f s",
                     step.label as NSString, step.expected, measured, delta))
        index += 1
        scheduleNext()
    }

    if let file = step.file {
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: completion)
    } else {
        node.scheduleBuffer(silence(step.expected), completionCallbackType: .dataPlayedBack, completionHandler: completion)
    }
    node.play()
}

print("Enchaînement de \(steps.count) étapes (3 phrases + 3 pauses) :")
scheduleNext()

let outcome = done.wait(timeout: .now() + 60)
engine.stop()

guard outcome == .success else {
    print("\néchec : l'enchaînement s'est bloqué à l'étape \(index) sur \(steps.count)")
    exit(1)
}

let worst = drift.map(abs).max() ?? 0
let total = steps.reduce(0) { $0 + $1.expected }
print(String(format: "\nDurée totale attendue %.2f s — écart maximal par étape %.2f s", total, worst))

// La latence de sortie ajoute quelques dizaines de millisecondes par étape ;
// au-delà d'un quart de seconde, l'enchaînement ne serait plus fiable.
if worst > 0.25 {
    print("échec : dérive trop importante")
    exit(1)
}
print("OK — l'enchaînement fichier/silence tient le rythme")
