import Foundation

/// Ce que les prises gardées disent de chaque son travaillé : combien de fois il
/// était à dire, combien de fois il était faux (`docs/module-profil.md`, étape 1).
///
/// Rien n'est stocké : c'est une projection des `PronunciationRecord`, recalculée à
/// l'ouverture de la séance.
struct PhonemeStats: Equatable {

    /// Une prise jugée, réduite à ce que le calcul lit.
    struct Take {
        let judgedAt: Date
        let attempt: Int
        let result: PronunciationResult
    }

    struct Count: Equatable {
        var expected = 0
        var faults = 0

        var rate: Double { expected == 0 ? 0 : Double(faults) / Double(expected) }
    }

    /// Le dernier mois : un son corrigé depuis cesse d'être visé (décision 1).
    static let window: TimeInterval = 30 * 24 * 3600
    /// En dessous, un son n'est pas jugé : sur deux essais, un raté ferait 50 %.
    static let minimumExpected = 6

    private(set) var counts: [SpanishTarget: Count] = [:]

    /// Seule la première prise d'une phrase compte : la suivante vient juste après
    /// le conseil, et sa réussite ne dit pas que le son est acquis.
    init(takes: [Take], now: Date) {
        let since = now.addingTimeInterval(-Self.window)
        for take in takes where take.attempt == 1 && take.judgedAt >= since && take.judgedAt <= now {
            for phone in take.result.words.flatMap(\.phonemes) {
                guard let target = Self.target(of: phone.expected) else { continue }
                counts[target, default: Count()].expected += 1
                // Un indice (le r roulé dit battu) n'est pas une faute.
                if phone.fault { counts[target, default: Count()].faults += 1 }
            }
        }
    }

    init(records: [PronunciationRecord], now: Date) {
        self.init(takes: records.compactMap { record in
            record.result.map { Take(judgedAt: record.judgedAt, attempt: record.attempt, result: $0) }
        }, now: now)
    }

    /// Le son travaillé que désigne un symbole du serveur. Mêmes familles que
    /// `SpanishSpelling` : le r battu et le r roulé, le b et sa forme douce. Le b
    /// est rangé sous `v` : c'est le seul b qu'un francophone rate.
    static func target(of symbol: String) -> SpanishTarget? {
        switch symbol {
        case "θ": .theta
        case "x": .jota
        case "r", "ɾ": .r
        case "b", "β": .v
        default: nil
        }
    }

    /// Les sons les plus ratés, assez vus pour en juger, et ratés au moins une fois.
    /// Le plus fort taux d'abord ; à taux égal, le plus de fautes.
    func weakest(_ limit: Int = 2) -> [SpanishTarget] {
        counts.filter { $0.value.expected >= Self.minimumExpected && $0.value.faults > 0 }
            .sorted { a, b in
                if a.value.rate != b.value.rate { return a.value.rate > b.value.rate }
                if a.value.faults != b.value.faults { return a.value.faults > b.value.faults }
                return a.key.rawValue < b.key.rawValue
            }
            .prefix(limit)
            .map(\.key)
    }
}

extension SpanishTarget {
    /// Le son dit en clair, pour la ligne « Aujourd'hui : surtout… ».
    var spokenName: String {
        switch self {
        case .theta: "le th anglais"
        case .jota: "la jota"
        case .r: "le r espagnol"
        case .v: "le v, dit comme un b"
        }
    }
}
