import Foundation
import SwiftData
import Testing
@testable import AssimilES

@MainActor
private final class Mic: PronunciationSound {
    var began = false
    func begin() { began = true }
    func end() { began = false }
    func startRecording() async -> Bool { true }
    func stopRecording() -> Data? { Data("prise".utf8) }
    func playNative(_ url: URL, onFinish: @escaping @MainActor () -> Void) {}
    func playTake(range: ClosedRange<Double>?, onFinish: @escaping @MainActor () -> Void) {}
    func stopPlayback() {}
}

/// Un juge qui rate la jota de chaque « j », et échoue une fois sur demande.
private final class Judge: PronunciationService, @unchecked Sendable {
    var failNext = false
    var judged: [String] = []

    func judge(audio: Data, text: String) async throws -> PronunciationResult {
        if failNext { failNext = false; throw ServerError.server("Le PC ne répond pas") }
        judged.append(text)
        let words = SpanishMatch.words(in: text).map { range -> JudgedWord in
            let word = String(SpanishMatch.fold(String(text[range])).folded)
            let phones = word.filter { "jrz".contains($0) }.map { letter -> JudgedPhone in
                let symbol = letter == "j" ? "x" : letter == "r" ? "ɾ" : "θ"
                return JudgedPhone(expected: symbol, heard: letter == "j" ? "ʁ" : nil, fault: letter == "j",
                                   reason: nil, hint: false, tip: nil, score: nil, threshold: nil, start: nil, end: nil)
            }
            return JudgedWord(text: word, fault: phones.contains(where: \.fault), phonemes: phones)
        }
        return PronunciationResult(words: words, heard: "", seconds: 0)
    }
}

@Suite("Placement : les sons")
@MainActor
struct SoundCheckTests {

    static let pack = VocabularyTestTests.pack

    @Test("Les phrases du paquet : 6, courtes, chaque son visé dans 3 phrases au moins")
    func sentences() {
        let sentences = Self.pack.soundSentences
        #expect(sentences.count == 6)
        for sentence in sentences {
            #expect(PronunciationDrill.wordRange.contains(PronunciationDrill.wordCount(sentence)), "\(sentence)")
        }
        for target in SpanishTarget.allCases {
            let count = sentences.filter { PronunciationDrill.targets(in: $0).contains(target) }.count
            #expect(count >= 3, "\(target) : \(count) phrases")
        }
    }

    @Test("Une phrase lue est jugée, gardée, et la suivante vient ; au bout, le bilan")
    func run() async {
        let judge = Judge()
        var kept: [(Int, String)] = []
        let check = SoundCheck(sentences: ["Mi hijo juega.", "Cierra la puerta."], service: judge, sound: Mic()) {
            number, text, _ in kept.append((number, text))
        }
        check.open()
        await check.toggleMic()
        #expect(check.phase == .recording)
        await check.toggleMic()
        #expect(check.index == 1)
        #expect(check.phase == .ready)

        // Le serveur échoue : on renvoie la même prise.
        judge.failNext = true
        await check.toggleMic()
        await check.toggleMic()
        #expect(check.phase == .failed("Le PC ne répond pas"))
        await check.retry()
        #expect(check.phase == .finished)
        #expect(kept.map(\.0) == [1, 2])
        #expect(judge.judged == ["Mi hijo juega.", "Cierra la puerta."])

        let outcome = check.outcome(now: Fixture.date(day: 1))
        #expect(outcome.counts["jota"] == SoundsOutcome.Count(expected: 2, faults: 2))
        #expect(outcome.counts["r"] == SoundsOutcome.Count(expected: 3, faults: 0)) // cie-rr-a compte deux r
        #expect(outcome.sentences == 2)
        // Deux jotas ne suffisent pas à juger un son (6 au moins, comme le profil).
        #expect(outcome.weak.isEmpty)
    }

    @Test("Assez de jotas ratées : le son est à travailler")
    func weak() {
        let phones = (0..<6).map { i in
            JudgedPhone(expected: "x", heard: "ʁ", fault: i < 4, reason: nil, hint: false, tip: nil,
                        score: nil, threshold: nil, start: nil, end: nil)
        }
        let result = PronunciationResult(words: [JudgedWord(text: "jajaja", fault: true, phonemes: phones)],
                                         heard: "", seconds: 0)
        let outcome = SoundsOutcome.make(results: [result], now: Fixture.date(day: 1))
        #expect(outcome.weakTargets == [.jota])
    }

    @Test("Après un échec, la phrase se passe")
    func skip() async {
        let judge = Judge()
        judge.failNext = true
        let check = SoundCheck(sentences: ["Mi hijo juega."], service: judge, sound: Mic())
        await check.toggleMic()
        await check.toggleMic()
        check.skip()
        #expect(check.phase == .finished)
        #expect(check.results.isEmpty)
    }

    @Test("Une prise du placement est gardée en leçon 0, et compte pour le profil des sons")
    func record() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let phone = JudgedPhone(expected: "x", heard: "ʁ", fault: true, reason: nil, hint: false, tip: nil,
                                score: nil, threshold: nil, start: nil, end: nil)
        let result = PronunciationResult(words: [JudgedWord(text: "hijo", fault: true, phonemes: [phone])],
                                         heard: "", seconds: 0)
        context.insert(PronunciationRecord(judgedAt: Fixture.date(day: 1), lesson: PronunciationRecord.placementLesson,
                                           sentence: 2, text: "Mi hijo juega.", attempt: 1, result: result))
        let records = try context.fetch(FetchDescriptor<PronunciationRecord>())
        #expect(records.first?.lesson == 0 && records.first?.faultSymbols == ["x"])
        #expect(PhonemeStats(records: records, now: Fixture.date(day: 2)).counts[.jota]?.faults == 1)
    }

    @Test("Un passage sans les sons se relit")
    func oldDetails() throws {
        #expect(try JSONDecoder().decode(PlacementDetails.self, from: Data("{}".utf8)).sounds == nil)
    }
}
