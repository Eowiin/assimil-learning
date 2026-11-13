import Foundation
import Testing
@testable import AssimilES

private func phone(_ expected: String, heard: String? = nil, fault: Bool = false, hint: Bool = false,
                   start: Double? = nil, end: Double? = nil) -> JudgedPhone {
    JudgedPhone(expected: expected, heard: heard, fault: fault, reason: nil, hint: hint, tip: nil,
                score: nil, threshold: nil, start: start, end: end)
}

private func word(_ text: String, _ phonemes: [JudgedPhone]) -> JudgedWord {
    JudgedWord(text: text, fault: phonemes.contains(where: \.fault), phonemes: phonemes)
}

// MARK: - Les lettres du son

@Suite("Prononciation : les lettres du son fautif")
struct SpanishSpellingTests {

    private func letters(_ text: String, _ phones: [JudgedPhone], fault index: Int) -> String? {
        let shown = DisplayedWord(id: 0, text: text, judged: word(text.lowercased(), phones))
        return SpanishSpelling.letters(of: phones[index], in: shown).map { String(text[$0]) }
    }

    @Test("Le r roulé de « jarra » : les deux r")
    func rolledR() {
        let phones = [phone("x"), phone("a"), phone("r", heard: "ʁ", fault: true), phone("a")]
        #expect(letters("jarra,", phones, fault: 2) == "rr")
        #expect(letters("jarra,", phones, fault: 0) == "j")
    }

    @Test("Le deuxième r d'un mot : la deuxième place")
    func secondR() {
        // « recorrer » : r, e, k, o, r (rr), e, ɾ.
        let phones = [phone("r"), phone("e"), phone("k"), phone("o"), phone("r"), phone("e"),
                      phone("ɾ", heard: "ʁ", fault: true)]
        let shown = DisplayedWord(id: 0, text: "recorrer", judged: word("recorrer", phones))
        let range = SpanishSpelling.letters(of: phones[6], in: shown)
        #expect(range.map { "recorrer"[$0] } == "r")
        #expect(range?.lowerBound == "recorrer".index(before: "recorrer".endIndex))
    }

    @Test("θ : le z, ou le c devant e et i ; jota : le j, ou le g devant e et i")
    func thetaAndJota() {
        #expect(letters("Cenicienta", [phone("θ", heard: "s", fault: true)], fault: 0) == "C")
        #expect(letters("gente", [phone("x", heard: "ʁ", fault: true)], fault: 0) == "g")
        #expect(letters("plaza.", [phone("p"), phone("l"), phone("a"), phone("θ", heard: "s", fault: true)],
                        fault: 3) == "z")
    }

    @Test("Le b et le v sont un même son")
    func bAndV() {
        #expect(letters("vivo", [phone("b"), phone("i"), phone("b", heard: "v", fault: true), phone("o")],
                        fault: 2) == "v")
    }

    @Test("Un son que l'orthographe ne montre pas : le mot entier")
    func otherSounds() {
        #expect(letters("casa", [phone("k", fault: true)], fault: 0) == nil)
        // La jota de « México » s'écrit x : on ne la cherche pas.
        #expect(letters("México", [phone("m"), phone("e"), phone("x", fault: true)], fault: 2) == nil)
    }
}

// MARK: - La séance

/// Un serveur qui rend, phrase après phrase, les jugements qu'on lui donne.
private final class ScriptedJudge: PronunciationService, @unchecked Sendable {
    var results: [PronunciationResult] = []
    var failNext: ServerError?
    var texts: [String] = []

    func judge(audio: Data, text: String) async throws -> PronunciationResult {
        texts.append(text)
        if let error = failNext { failNext = nil; throw error }
        return results.isEmpty ? PronunciationResult(words: [], heard: "", seconds: 0) : results.removeFirst()
    }
}

@MainActor
private final class FakeSound: PronunciationSound {
    var micGranted = true
    var played: [String] = []
    func begin() {}
    func end() {}
    func startRecording() async -> Bool { micGranted }
    func stopRecording() -> Data? { Data("prise".utf8) }
    func playNative(_ url: URL, onFinish: @escaping @MainActor () -> Void) { played.append("natif \(url.lastPathComponent)") }
    func playTake(range: ClosedRange<Double>?, onFinish: @escaping @MainActor () -> Void) {
        played.append(range.map { String(format: "mot %.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "prise")
    }
    func stopPlayback() {}
}

@Suite("Prononciation : la séance")
@MainActor
struct PronunciationSessionTests {

    private let sentences = [
        DrillSentence(lesson: 1, n: 2, text: "Una jarra, por favor.", clip: AudioClip(file: "S02.m4a", duration: 2, n: 2),
                      targets: [.jota, .r, .v]),
        DrillSentence(lesson: 2, n: 1, text: "La cena.", clip: AudioClip(file: "S01.m4a", duration: 2, n: 1),
                      targets: [.theta]),
    ]

    private let faulty = PronunciationResult(words: [
        word("una", []),
        word("jarra", [phone("x"), phone("a"), phone("r", heard: "ʁ", fault: true, start: 0.5, end: 0.6), phone("a", start: 0.6, end: 0.7)]),
        word("por", [phone("r", heard: "ɾ", hint: true)]),
        word("favor", [phone("b", heard: "v", fault: true, start: 1.0, end: 1.1)]),
    ], heard: "", seconds: 0.2)

    private let clean = PronunciationResult(words: [word("una", []), word("jarra", []), word("por", []), word("favor", [])],
                                            heard: "", seconds: 0.2)

    private func session(_ judge: ScriptedJudge, sound: FakeSound? = nil) -> PronunciationSession {
        PronunciationSession(sentences: sentences, service: judge, sound: sound ?? FakeSound(),
                             nativeURL: { URL(fileURLWithPath: "/audio/L00\($0.lesson)/\($0.clip.file)") })
    }

    private func read(_ s: PronunciationSession) async {
        await s.toggleMic()
        await s.toggleMic()
    }

    @Test("La phrase s'affiche telle quelle, puis jugée : la première faute est détaillée")
    func judged() async {
        let judge = ScriptedJudge()
        judge.results = [faulty]
        let s = session(judge)
        #expect(s.phase == .ready)
        #expect(s.words.map(\.text) == ["Una", "jarra,", "por", "favor."])

        await read(s)
        #expect(judge.texts == ["Una jarra, por favor."])
        #expect(s.phase == .judged)
        #expect(s.words.map(\.isFault) == [false, true, false, true])
        #expect(s.focusWord?.text == "jarra,")
        #expect(s.focusPhone?.heard == "ʁ")
        // Une faute, une seule prise : pas encore la suivante.
        #expect(!s.canAdvance)
    }

    @Test("Toucher un autre mot montre sa faute ; un mot sans jugement ne change rien")
    func selectWord() async {
        let judge = ScriptedJudge()
        judge.results = [faulty]
        let s = session(judge)
        await read(s)
        s.select(s.words[3])
        #expect(s.focusPhone?.heard == "v")
        s.select(s.words[2])
        #expect(s.focusWord?.text == "por")
        #expect(s.focusPhone?.hint == true)
    }

    @Test("Sans faute : on passe tout de suite. Avec : après une nouvelle tentative, même ratée")
    func advance() async {
        let judge = ScriptedJudge()
        judge.results = [faulty, faulty, clean]
        let s = session(judge)
        await read(s)
        #expect(!s.canAdvance)
        await read(s)
        #expect(s.attempts == 2)
        #expect(s.canAdvance)
        s.next()
        #expect(s.index == 1)
        #expect(s.phase == .ready)
        #expect(s.result == nil)
        #expect(s.words.map(\.text) == ["La", "cena."])

        await read(s)
        #expect(s.canAdvance)
        #expect(s.isLast)
        s.next()
        #expect(s.phase == .finished)
    }

    @Test("Le bilan compte les fautes de la dernière prise de chaque phrase")
    func summary() async {
        let judge = ScriptedJudge()
        judge.results = [faulty, faulty, clean]
        let s = session(judge)
        await read(s); await read(s); s.next()
        await read(s); s.next()
        #expect(s.summary.map(\.symbol) == ["b", "r"])
        #expect(s.summary.map(\.count) == [1, 1])
    }

    @Test("Un échec garde la prise : on la renvoie, ou on passe la phrase")
    func failure() async {
        let judge = ScriptedJudge()
        judge.failNext = .network("Le PC ne répond pas : est-il allumé ?")
        judge.results = [clean]
        let s = session(judge)
        await read(s)
        #expect(s.phase == .failed("Le PC ne répond pas : est-il allumé ?"))
        await s.retry()
        #expect(judge.texts.count == 2)
        #expect(s.phase == .judged)

        judge.failNext = .server("L'enregistrement est trop court.")
        s.next()
        await read(s)
        #expect(s.phase == .failed("L'enregistrement est trop court."))
        s.next()
        #expect(s.phase == .finished)
    }

    @Test("Micro refusé : on le dit, rien ne part")
    func micDenied() async {
        let judge = ScriptedJudge()
        let sound = FakeSound()
        sound.micGranted = false
        let s = session(judge, sound: sound)
        await s.toggleMic()
        #expect(s.phase == .micDenied)
        #expect(judge.texts.isEmpty)
    }

    @Test("Annuler une prise : rien n'est envoyé, le jugement d'avant reste")
    func cancel() async {
        let judge = ScriptedJudge()
        judge.results = [faulty]
        let s = session(judge)
        await read(s)
        await s.toggleMic()
        s.cancelRecording()
        #expect(s.phase == .judged)
        #expect(judge.texts.count == 1)
    }

    @Test("Le natif, la prise, et le mot seul avec un peu de marge")
    func listening() async {
        let judge = ScriptedJudge()
        judge.results = [faulty]
        let sound = FakeSound()
        let s = session(judge, sound: sound)
        s.playNative()
        #expect(s.playing == .native)
        s.playNative()
        #expect(s.playing == .none)
        await read(s)
        s.playTake()
        s.playFocusWord()
        #expect(sound.played == ["natif S02.m4a", "prise", "mot 0.42-0.78"])
        #expect(s.playing == .word)
    }

    @Test("Chaque prise jugée est remise à l'écran pour être gardée, avec son numéro de tentative")
    func judgedTakesAreHandedOver() async {
        let judge = ScriptedJudge()
        judge.results = [faulty, clean]
        var kept: [(String, Int, Bool)] = []
        let s = PronunciationSession(sentences: sentences, service: judge, sound: FakeSound(),
                                     nativeURL: { _ in nil },
                                     onJudged: { sentence, attempt, result in
                                         kept.append((sentence.id, attempt, result.hasFault))
                                     })
        await read(s)
        await read(s)
        // Une prise qui échoue n'est pas gardée.
        judge.failNext = .network("Pas de réseau")
        await read(s)
        #expect(kept.map(\.0) == ["1-2", "1-2"])
        #expect(kept.map(\.1) == [1, 2])
        #expect(kept.map(\.2) == [true, false])
    }

    @Test("Aucune phrase : la séance est finie d'emblée")
    func empty() {
        let s = PronunciationSession(sentences: [], service: ScriptedJudge(), sound: FakeSound(), nativeURL: { _ in nil })
        #expect(s.phase == .finished)
        #expect(s.summary.isEmpty)
    }
}
