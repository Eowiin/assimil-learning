import Foundation
import Testing
@testable import AssimilES

/// Un hasard rejouable : le même germe donne toujours le même tirage.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func phone(_ expected: String, fault: Bool = false, hint: Bool = false) -> JudgedPhone {
    JudgedPhone(expected: expected, heard: fault || hint ? "?" : nil, fault: fault, reason: nil, hint: hint,
                tip: nil, score: nil, threshold: nil, start: nil, end: nil)
}

private func take(_ phones: [JudgedPhone], daysAgo: Double = 1, attempt: Int = 1,
                  now: Date) -> PhonemeStats.Take {
    PhonemeStats.Take(judgedAt: now.addingTimeInterval(-daysAgo * 24 * 3600), attempt: attempt,
                      result: PronunciationResult(words: [JudgedWord(text: "mot", fault: phones.contains(where: \.fault),
                                                                     phonemes: phones)],
                                                  heard: "", seconds: 0.2))
}

@Suite("Profil : les sons les plus ratés")
struct PhonemeStatsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Chaque son attendu compte, ses fautes à part ; un indice n'est pas une faute")
    func counts() {
        let stats = PhonemeStats(takes: [take([phone("θ", fault: true), phone("θ"), phone("x"),
                                               phone("r", hint: true), phone("s", fault: true)], now: now)],
                                 now: now)
        #expect(stats.counts[.theta] == PhonemeStats.Count(expected: 2, faults: 1))
        #expect(stats.counts[.jota] == PhonemeStats.Count(expected: 1, faults: 0))
        #expect(stats.counts[.r] == PhonemeStats.Count(expected: 1, faults: 0))
        // Le s n'est pas un son travaillé : il n'est compté nulle part.
        #expect(stats.counts.count == 3)
    }

    @Test("Les deux r font un son, le b et le β vont vers le v")
    func families() {
        #expect(PhonemeStats.target(of: "r") == .r)
        #expect(PhonemeStats.target(of: "ɾ") == .r)
        #expect(PhonemeStats.target(of: "β") == .v)
        #expect(PhonemeStats.target(of: "b") == .v)
        #expect(PhonemeStats.target(of: "x") == .jota)
        #expect(PhonemeStats.target(of: "θ") == .theta)
        #expect(PhonemeStats.target(of: "a") == nil)
    }

    @Test("Seule la première prise compte, et seulement le dernier mois")
    func window() {
        let stats = PhonemeStats(takes: [
            take([phone("θ", fault: true)], now: now),
            take([phone("θ")], attempt: 2, now: now),          // juste après le conseil
            take([phone("θ", fault: true)], daysAgo: 31, now: now),  // trop ancienne
        ], now: now)
        #expect(stats.counts[.theta] == PhonemeStats.Count(expected: 1, faults: 1))
    }

    @Test("Les plus ratés : assez vus, ratés au moins une fois, le plus fort taux d'abord")
    func weakest() {
        let takes = (0..<6).map { i in
            take([phone("θ", fault: i < 3),     // 3 sur 6
                  phone("x", fault: i < 5),     // 5 sur 6
                  phone("r"),                   // jamais raté
                  ] + (i < 2 ? [phone("β", fault: true)] : []),  // 2 sur 2 : pas assez vu
                 now: now)
        }
        let stats = PhonemeStats(takes: takes, now: now)
        #expect(stats.weakest() == [.jota, .theta])
        #expect(stats.weakest(1) == [.jota])
    }

    @Test("Sans historique, aucun son visé")
    func empty() {
        #expect(PhonemeStats(takes: [], now: now).weakest().isEmpty)
    }
}

@Suite("Profil : la séance vise les sons ratés")
struct FocusedDrillTests {

    private let manifest = Fixture.manifest(lessonCount: 10, sentences: 4)

    private func text(_ number: Int, _ sentences: [String]) -> LessonText {
        let items = sentences.enumerated().map { i, es in #"{"n": \#(i + 1), "es": "\#(es)"}"# }
        return try! Fixture.text(#"{"number": \#(number), "sentences": [\#(items.joined(separator: ","))]}"#)
    }

    private var pool: [DrillSentence] {
        let texts = [
            1: text(1, ["Las cinco amigas cenan en la plaza.",   // θ
                        "Hace sol en la ciudad de Zaragoza.",    // θ, r
                        "Quiero un vaso de vino, por favor.",    // r, v
                        "Mi perro se llama Ramón y vive aquí."]), // r, v
            2: text(2, ["Hay un hotel en la calle mayor.",       // r
                        "Tomo un zumo de naranja.",              // θ, r, jota
                        "¿Dónde está la gente de Jaén?",         // jota
                        "El tren sale a las ocho."]),            // r
        ]
        return PronunciationDrill.candidates(lessons: [1, 2], manifest: manifest) { texts[$0] }
    }

    @Test("Trois phrases sur cinq contiennent le son le plus raté")
    func focusOne() {
        #expect(pool.count == 8)
        for seed in 0..<20 {
            var generator = Seeded(state: UInt64(seed))
            let picked = PronunciationDrill.pick(from: pool, focus: [.theta], using: &generator)
            #expect(picked.count == 5)
            #expect(Set(picked.map(\.id)).count == 5)
            #expect(picked.count { $0.targets.contains(.theta) } >= 3)
        }
    }

    @Test("Deux sons visés : chacun au moins une fois")
    func focusTwo() {
        for seed in 0..<20 {
            var generator = Seeded(state: UInt64(seed))
            let picked = PronunciationDrill.pick(from: pool, focus: [.v, .jota], using: &generator)
            #expect(picked.contains { $0.targets.contains(.v) })
            #expect(picked.contains { $0.targets.contains(.jota) })
            #expect(picked.count { !$0.targets.isDisjoint(with: [.v, .jota]) } >= 3)
        }
    }

    @Test("Un son visé sans phrase n'est pas annoncé")
    func announced() {
        let jotaOnly = pool.filter { $0.targets == [.jota] }
        #expect(PronunciationDrill.announced([.theta, .jota], in: jotaOnly) == [.jota])
        #expect(PronunciationDrill.announced([], in: pool).isEmpty)
    }

    @Test("La ligne de l'écran")
    func focusText() {
        #expect(PronunciationView.focusText([]) == nil)
        #expect(PronunciationView.focusText([.theta]) == "Aujourd'hui : surtout le th anglais")
        #expect(PronunciationView.focusText([.jota, .theta]) == "Aujourd'hui : surtout la jota et le th anglais")
    }
}
