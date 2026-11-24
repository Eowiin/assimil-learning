import Foundation

// Le réflexe de la rafale (`docs/moteur-adaptatif.md`, étape 5c-3) : le temps entre la
// fin de la réplique de l'IA et le moment où l'apprenant se met à parler. C'est l'arrivée
// de la voix qui compte, pas l'appui sur le micro : toucher vite puis chercher ses mots
// n'est pas un réflexe.

/// Repère le début de la voix dans les niveaux du micro, relevés toutes les 50 ms.
/// Le tout début de la prise est ignoré (le bruit du toucher), et il faut deux relevés
/// de suite au-dessus du seuil : un claquement isolé ne fait pas une voix.
struct VoiceOnsetDetector {
    /// Le niveau d'une voix parlée près du téléphone, en dB (0 : le plus fort).
    static let threshold: Float = -35
    /// Ce qui suit l'appui n'est pas écouté.
    static let ignored: TimeInterval = 0.15
    static let consecutive = 2
    /// L'intervalle des relevés.
    static let interval: Duration = .milliseconds(50)

    let startedAt: Date
    private var loud: Date?
    private var count = 0

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Un relevé. Rend le début de la voix (le premier des relevés forts) quand il est
    /// trouvé.
    mutating func feed(level: Float, at time: Date) -> Date? {
        guard time.timeIntervalSince(startedAt) >= Self.ignored, level > Self.threshold else {
            loud = nil
            count = 0
            return nil
        }
        if loud == nil { loud = time }
        count += 1
        return count >= Self.consecutive ? loud : nil
    }
}

/// Les temps de réaction d'une rafale, et la série de réponses rapides.
struct ReflexMeter: Equatable {
    /// Une réponse commencée en moins de 4,5 s est un réflexe.
    static let threshold: TimeInterval = 4.5

    private(set) var latencies: [Double] = []
    /// Les réflexes d'affilée, jusqu'à la dernière réponse.
    private(set) var streak = 0
    private(set) var bestStreak = 0

    var last: Double? { latencies.last }
    var lastWasReflex: Bool { last.map { $0 < Self.threshold } ?? false }

    var average: Double? {
        latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
    }

    mutating func record(_ latency: Double) {
        latencies.append(latency)
        if latency < Self.threshold {
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
        }
    }

    /// « 3,2 s ».
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR"))) + " s"
    }

    /// Le badge au-dessus du micro, après une réponse : la série, ou le temps seul.
    var badge: String? {
        guard let last else { return nil }
        if streak >= 2 { return "Réflexe ×\(streak) · \(Self.seconds(last))" }
        if lastWasReflex { return "Réflexe · \(Self.seconds(last))" }
        return "Lancé en \(Self.seconds(last))"
    }

    /// La ligne du récapitulatif.
    var averageLabel: String? {
        average.map { "Tu prends la parole en \(Self.seconds($0)) en moyenne" }
    }

    var bestStreakLabel: String {
        switch bestStreak {
        case 0: "Aucune réponse sous \(Self.seconds(Self.threshold)) cette fois"
        case 1: "Meilleure série : 1 réponse réflexe"
        default: "Meilleure série : \(bestStreak) réponses réflexes d'affilée"
        }
    }
}
