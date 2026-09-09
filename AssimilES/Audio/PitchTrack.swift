import Foundation
import AVFoundation
import Accelerate

/// La courbe d'intonation d'un enregistrement : la hauteur de la voix trame par
/// trame, ramenée au registre du locuteur.
///
/// **Pourquoi en demi-tons et pas en hertz.** Une voix d'homme et celle d'un
/// comédien de studio ne vivent pas dans la même octave, et ça n'a rien à voir avec
/// l'intonation. En rapportant chaque trame à la médiane du locuteur, on efface le
/// registre et on ne garde que la *forme* — où ça monte, où ça descend, de combien.
/// C'est ce qu'on apprend d'une langue ; la hauteur absolue, non.
struct PitchTrack {

    struct Frame {
        let time: Double
        /// `nil` sur les trames non voisées : consonnes sourdes, souffles, silences.
        /// Une courbe d'intonation a des trous, et les combler serait inventer.
        let semitones: Double?
        let energy: Double
    }

    let frames: [Frame]
    /// La hauteur médiane du locuteur, en hertz — le zéro de l'échelle.
    let medianHz: Double
    let duration: Double

    var voiced: [Frame] { frames.filter { $0.semitones != nil } }
    var isUsable: Bool { voiced.count >= 8 }
}

/// Détection de hauteur par autocorrélation normalisée.
///
/// Écrit ici plutôt que pris à `SFVoiceAnalytics` pour une raison précise : il faut
/// la même mesure sur les deux enregistrements, celui d'Ethan **et** le clip
/// Assimil. Un chemin qui passe par la reconnaissance vocale ne donne pas ça — et
/// le projet calcule déjà ses propres mesures partout ailleurs.
enum PitchTracker {

    /// 16 kHz suffit très largement : la voix parlée vit entre 70 et 400 Hz, et
    /// travailler à 44,1 kHz coûterait huit fois plus pour rien.
    static let workingRate = 16_000.0
    static let frameSize = 1024          // 64 ms
    static let hop = 256                 // 16 ms, ~62 trames par seconde
    static let minHz = 70.0
    static let maxHz = 400.0
    /// Seuil de YIN : en dessous, la trame est déclarée voisée.
    ///
    /// Calibré sur 4 364 trames non silencieuses de quatre leçons du corpus, et non
    /// repris de l'article d'origine : 0,15 n'y retenait que 36 % des trames, 0,25
    /// en retient 51 %, ce qui est l'ordre de voisement attendu d'une phrase parlée.
    static let yinThreshold = 0.25
    /// Les trames trop faibles sont écartées avant tout calcul : du silence a une
    /// autocorrélation, elle ne veut simplement rien dire.
    static let silenceFloor = 0.004

    static func track(_ url: URL) -> PitchTrack? {
        guard let samples = monoSamples(url) else { return nil }
        return track(samples: samples, sampleRate: workingRate)
    }

    static func track(samples: [Float], sampleRate: Double) -> PitchTrack? {
        guard samples.count > frameSize else { return nil }

        let minLag = Int(sampleRate / maxHz)
        let maxLag = min(Int(sampleRate / minHz), frameSize / 2)
        guard maxLag > minLag else { return nil }

        var raw: [(time: Double, hz: Double?, energy: Double)] = []
        var start = 0
        while start + frameSize <= samples.count {
            let frame = Array(samples[start..<(start + frameSize)])
            let time = Double(start) / sampleRate
            let energy = rms(frame)

            if energy < silenceFloor {
                raw.append((time, nil, energy))
            } else {
                let hz = fundamental(of: centred(frame), minLag: minLag, maxLag: maxLag,
                                     sampleRate: sampleRate)
                raw.append((time, hz, energy))
            }
            start += hop
        }

        let voicedHz = raw.compactMap(\.hz).sorted()
        guard !voicedHz.isEmpty else { return nil }
        let median = voicedHz[voicedHz.count / 2]

        let frames = raw.map { entry in
            PitchTrack.Frame(time: entry.time,
                             semitones: entry.hz.map { 12 * log2($0 / median) },
                             energy: entry.energy)
        }
        return PitchTrack(frames: frames,
                          medianHz: median,
                          duration: Double(samples.count) / sampleRate)
    }

    // MARK: - Le cœur du calcul

    /// La courbe de différence de YIN, normalisée par sa moyenne cumulée.
    ///
    /// Sortie à part de la décision pour une raison pratique : c'est elle qu'on
    /// regarde pour calibrer le seuil sur le corpus, plutôt que de le deviner.
    /// `normalized[tau]` vaut 0 quand la trame se répète exactement à ce décalage,
    /// 1 quand rien ne s'y répète.
    static func yinCurve(of frame: [Float], maxLag: Int) -> [Double]? {
        // Toutes les valeurs de tau se comparent sur une fenêtre de même longueur,
        // sinon la différence décroît mécaniquement avec le décalage.
        let window = frame.count - maxLag
        guard window > 0, maxLag >= 1 else { return nil }

        var difference = [Double](repeating: 0, count: maxLag + 1)
        frame.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            var head: Float = 0
            vDSP_svesq(base, 1, &head, vDSP_Length(window))
            for lag in 1...maxLag {
                var dot: Float = 0
                var tail: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(window))
                vDSP_svesq(base + lag, 1, &tail, vDSP_Length(window))
                difference[lag] = Double(head) + Double(tail) - 2 * Double(dot)
            }
        }

        var normalized = [Double](repeating: 1, count: maxLag + 1)
        var runningSum = 0.0
        for lag in 1...maxLag {
            runningSum += difference[lag]
            normalized[lag] = runningSum > 0
                ? difference[lag] * Double(lag) / runningSum
                : 1
        }
        return normalized
    }

    /// Hauteur par la méthode YIN.
    ///
    /// **Pourquoi pas une autocorrélation normalisée, essayée d'abord.** Elle
    /// attrapait les harmoniques : sur une phrase du corpus, une voix réellement à
    /// ~95 Hz ressortait en 95, 180, 260 et 365 Hz selon les trames — des multiples.
    /// Une voix grave encodée en AAC 64 k a un fondamental faible devant ses
    /// harmoniques, et le maximum de corrélation tombe alors sur un lag trop court.
    ///
    /// YIN corrige exactement ça : sa fonction de différence est divisée par sa
    /// propre moyenne cumulée, ce qui pénalise les petits décalages, puis on retient
    /// **le premier** creux sous le seuil plutôt que le meilleur. Le premier, parce
    /// que le meilleur est souvent un multiple de la période.
    private static func fundamental(of frame: [Float], minLag: Int, maxLag: Int,
                                    sampleRate: Double) -> Double? {
        guard let normalized = yinCurve(of: frame, maxLag: maxLag) else { return nil }

        // Le premier creux sous le seuil, descendu jusqu'à son minimum local.
        var chosen: Int?
        var lag = minLag
        while lag <= maxLag {
            if normalized[lag] < yinThreshold {
                while lag + 1 <= maxLag, normalized[lag + 1] < normalized[lag] { lag += 1 }
                chosen = lag
                break
            }
            lag += 1
        }
        guard let peak = chosen, peak > 0, peak < maxLag else { return nil }

        // Interpolation parabolique : sans elle, la hauteur est quantifiée par le
        // pas d'échantillonnage et la courbe monte en escalier.
        let before = normalized[peak - 1]
        let centre = normalized[peak]
        let after = normalized[peak + 1]
        let denominator = 2 * (2 * centre - before - after)
        let shift = denominator == 0 ? 0 : (after - before) / denominator
        let refined = Double(peak) + shift

        return refined > 0 ? sampleRate / refined : nil
    }

    static func centred(_ frame: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(frame.count))
        var negated = -mean
        var out = [Float](repeating: 0, count: frame.count)
        vDSP_vsadd(frame, 1, &negated, &out, 1, vDSP_Length(frame.count))
        return out
    }

    static func rms(_ frame: [Float]) -> Double {
        var value: Float = 0
        vDSP_rmsqv(frame, 1, &value, vDSP_Length(frame.count))
        return Double(value)
    }

    // MARK: - Lecture

    /// Rend le fichier en mono 16 kHz, quel que soit son format d'origine : les
    /// deux enregistrements comparés doivent être mesurés à l'identique.
    static func monoSamples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: workingRate,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return nil }

        let ratio = workingRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }

        var finished = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if finished {
                status.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length))
            else {
                status.pointee = .endOfStream
                return nil
            }
            do { try file.read(into: input) } catch {
                status.pointee = .endOfStream
                return nil
            }
            finished = true
            status.pointee = input.frameLength > 0 ? .haveData : .endOfStream
            return input.frameLength > 0 ? input : nil
        }

        guard conversionError == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
