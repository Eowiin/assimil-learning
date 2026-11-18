import Foundation
import Observation

/// Le diagnostic des sons du placement (étape 3d) : quelques phrases lues à froid, une
/// fois chacune, sans modèle à imiter ni correction en cours de route. Le serveur juge
/// chaque prise (`POST /pronunciation`) ; le bilan dit, pour chacun des quatre sons
/// qu'un francophone rate, combien de fois il était à dire et combien il a été raté.
@Observable
@MainActor
final class SoundCheck {

    enum Phase: Equatable {
        case ready
        case recording
        case judging
        case failed(String)
        case micDenied
        case finished
    }

    let sentences: [String]
    private(set) var index = 0
    private(set) var phase: Phase = .ready
    /// Les phrases jugées, dans l'ordre.
    private(set) var results: [PronunciationResult] = []

    private let service: any PronunciationService
    private let sound: any PronunciationSound
    /// Appelé à chaque prise jugée : l'écran la garde (`PronunciationRecord`).
    private let onJudged: (Int, String, PronunciationResult) -> Void
    private var pendingTake: Data?

    init(sentences: [String], service: any PronunciationService, sound: any PronunciationSound,
         onJudged: @escaping (Int, String, PronunciationResult) -> Void = { _, _, _ in }) {
        self.sentences = sentences
        self.service = service
        self.sound = sound
        self.onJudged = onJudged
        if sentences.isEmpty { phase = .finished }
    }

    var current: String? { index < sentences.count ? sentences[index] : nil }

    func open() { sound.begin() }

    func close() {
        if phase == .recording { _ = sound.stopRecording() }
        sound.stopPlayback()
        sound.end()
    }

    /// Un premier appui écoute, le second envoie ; la phrase suivante vient d'elle-même.
    func toggleMic() async {
        switch phase {
        case .ready, .micDenied:
            phase = await sound.startRecording() ? .recording : .micDenied
        case .recording:
            guard let take = sound.stopRecording(), !take.isEmpty else {
                phase = .ready
                return
            }
            await judge(take)
        case .judging, .failed, .finished:
            break
        }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        _ = sound.stopRecording()
        phase = .ready
    }

    func retry() async {
        guard case .failed = phase, let pendingTake else { return }
        await judge(pendingTake)
    }

    /// Après un échec du serveur : la phrase est laissée de côté.
    func skip() {
        guard case .failed = phase else { return }
        pendingTake = nil
        advance()
    }

    /// Le bilan des phrases jugées.
    func outcome(now: Date = .now) -> SoundsOutcome {
        SoundsOutcome.make(results: results, now: now)
    }

    private func judge(_ take: Data) async {
        guard let current else { return }
        phase = .judging
        pendingTake = take
        do {
            let result = try await service.judge(audio: take, text: current)
            results.append(result)
            onJudged(index + 1, current, result)
            pendingTake = nil
            advance()
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func advance() {
        index += 1
        phase = index < sentences.count ? .ready : .finished
    }
}

/// Ce que le diagnostic dit des sons, gardé dans le passage du placement.
struct SoundsOutcome: Codable, Equatable, Sendable {
    struct Count: Codable, Equatable, Sendable {
        let expected: Int
        let faults: Int
    }

    let skipped: Bool
    /// Par son (`SpanishTarget.rawValue`) : combien à dire, combien ratés.
    let counts: [String: Count]
    /// Les sons à travailler, le plus raté d'abord (`PhonemeStats.weakest`).
    let weak: [String]
    let sentences: Int

    static func make(results: [PronunciationResult], now: Date) -> SoundsOutcome {
        let stats = PhonemeStats(takes: results.map { PhonemeStats.Take(judgedAt: now, attempt: 1, result: $0) },
                                 now: now)
        return SoundsOutcome(
            skipped: false,
            counts: Dictionary(uniqueKeysWithValues: stats.counts.map {
                ($0.key.rawValue, Count(expected: $0.value.expected, faults: $0.value.faults))
            }),
            weak: stats.weakest(SpanishTarget.allCases.count).map(\.rawValue),
            sentences: results.count)
    }

    static let skippedOutcome = SoundsOutcome(skipped: true, counts: [:], weak: [], sentences: 0)

    var weakTargets: [SpanishTarget] { weak.compactMap(SpanishTarget.init(rawValue:)) }
}
