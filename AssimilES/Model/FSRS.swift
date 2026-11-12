import Foundation

/// L'ordonnanceur FSRS-6, porté de l'implémentation officielle (py-fsrs 6.3.2,
/// `fsrs/scheduler.py`) et vérifié contre elle (`FSRSTests`). Il décide, d'après la
/// note donnée à une carte, quand elle doit revenir.
///
/// Logique pure, sans SwiftData : `CardReview.grade` l'applique à une `Card`.
///
/// Choix, par rapport aux réglages de py-fsrs :
/// - **paramètres par défaut**, sans optimisation : il faudrait des mois de journal ;
/// - **sans « fuzz »** (le petit hasard qui étale les échéances) : le comportement
///   reste prévisible et testable, au prix de révisions un peu plus groupées ;
/// - étapes d'apprentissage d'Anki : 1 puis 10 minutes, 10 minutes en réapprentissage.
enum FSRS {

    /// La note donnée à une carte. Les valeurs sont celles de FSRS et du journal
    /// (`ReviewLog.rating`).
    enum Rating: Int, CaseIterable {
        case again = 1, hard, good, easy
    }

    /// Où en est une carte. Une carte neuve est en apprentissage, à l'étape 0, sans
    /// stabilité ni difficulté.
    enum State: String {
        case learning, review, relearning
    }

    struct Memory: Equatable {
        var state: State = .learning
        /// L'étape d'apprentissage ou de réapprentissage ; nil en révision.
        var step: Int? = 0
        var stability: Double?
        var difficulty: Double?
        var due: Date
        var lastReview: Date?

        static func new(at date: Date) -> Memory { Memory(due: date) }
    }

    struct Parameters {
        var w: [Double] = [0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
                           1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
                           1.8729, 0.5425, 0.0912, 0.0658, 0.1542]
        var desiredRetention = 0.9
        var learningSteps: [TimeInterval] = [60, 600]
        var relearningSteps: [TimeInterval] = [600]
        var maximumInterval = 36500

        static let standard = Parameters()

        var decay: Double { -w[20] }
        var factor: Double { pow(0.9, 1 / decay) - 1 }
    }

    static let stabilityMin = 0.001
    static let day: TimeInterval = 86_400

    // MARK: - La revue

    static func review(_ memory: Memory, rating: Rating, at date: Date,
                       parameters p: Parameters = .standard) -> Memory {
        var m = memory
        let daysSinceLast = m.lastReview.map { wholeDays(from: $0, to: date) }
        let interval: TimeInterval

        switch m.state {
        case .learning, .relearning:
            let steps = m.state == .learning ? p.learningSteps : p.relearningSteps
            let step = m.step ?? 0
            if m.state == .learning, m.stability == nil || m.difficulty == nil {
                m.stability = initialStability(rating, p)
                m.difficulty = initialDifficulty(rating, clamp: true, p)
            } else {
                updateMemory(&m, rating: rating, daysSinceLast: daysSinceLast, at: date, p)
            }

            if steps.isEmpty || (step >= steps.count && rating != .again) {
                interval = graduate(&m, p)
            } else {
                switch rating {
                case .again:
                    m.step = 0
                    interval = steps[0]
                case .hard:
                    // L'étape ne change pas.
                    if step == 0, steps.count == 1 { interval = steps[0] * 1.5 }
                    else if step == 0 { interval = (steps[0] + steps[1]) / 2 }
                    else { interval = steps[step] }
                case .good:
                    if step + 1 == steps.count { interval = graduate(&m, p) }
                    else { m.step = step + 1; interval = steps[step + 1] }
                case .easy:
                    interval = graduate(&m, p)
                }
            }

        case .review:
            let s = m.stability ?? stabilityMin, d = m.difficulty ?? 5
            if let days = daysSinceLast, days < 1 {
                m.stability = shortTermStability(s, rating, p)
            } else {
                m.stability = nextStability(d, s, retrievability(m, at: date, p), rating, p)
            }
            m.difficulty = nextDifficulty(d, rating, p)
            if rating == .again, !p.relearningSteps.isEmpty {
                m.state = .relearning
                m.step = 0
                interval = p.relearningSteps[0]
            } else {
                interval = TimeInterval(nextInterval(m.stability!, p)) * day
            }
        }

        m.due = date.addingTimeInterval(interval)
        m.lastReview = date
        return m
    }

    /// La probabilité de se souvenir de la carte à cette date.
    static func retrievability(_ m: Memory, at date: Date, _ p: Parameters = .standard) -> Double {
        guard let last = m.lastReview, let s = m.stability else { return 0 }
        let elapsed = Double(max(0, wholeDays(from: last, to: date)))
        return pow(1 + p.factor * elapsed / s, p.decay)
    }

    // MARK: - Les formules (mêmes noms que py-fsrs)

    /// En apprentissage ou réapprentissage, une carte déjà notée : le même jour, la
    /// stabilité à court terme ; sinon, la formule de révision.
    private static func updateMemory(_ m: inout Memory, rating: Rating, daysSinceLast: Int?,
                                     at date: Date, _ p: Parameters) {
        let s = m.stability ?? stabilityMin, d = m.difficulty ?? 5
        if let days = daysSinceLast, days < 1 {
            m.stability = shortTermStability(s, rating, p)
        } else {
            m.stability = nextStability(d, s, retrievability(m, at: date, p), rating, p)
        }
        m.difficulty = nextDifficulty(d, rating, p)
    }

    private static func graduate(_ m: inout Memory, _ p: Parameters) -> TimeInterval {
        m.state = .review
        m.step = nil
        return TimeInterval(nextInterval(m.stability!, p)) * day
    }

    private static func initialStability(_ r: Rating, _ p: Parameters) -> Double {
        max(p.w[r.rawValue - 1], stabilityMin)
    }

    private static func initialDifficulty(_ r: Rating, clamp: Bool, _ p: Parameters) -> Double {
        let d = p.w[4] - exp(p.w[5] * Double(r.rawValue - 1)) + 1
        return clamp ? clampDifficulty(d) : d
    }

    private static func nextInterval(_ s: Double, _ p: Parameters) -> Int {
        let raw = s / p.factor * (pow(p.desiredRetention, 1 / p.decay) - 1)
        // `round` de Python arrondit les demis au pair : 2,5 → 2. Même règle ici.
        let days = Int(raw.rounded(.toNearestOrEven))
        return min(max(days, 1), p.maximumInterval)
    }

    private static func shortTermStability(_ s: Double, _ r: Rating, _ p: Parameters) -> Double {
        var increase = exp(p.w[17] * (Double(r.rawValue) - 3 + p.w[18])) * pow(s, -p.w[19])
        if r != .again { increase = max(increase, 1) }
        return max(s * increase, stabilityMin)
    }

    private static func nextDifficulty(_ d: Double, _ r: Rating, _ p: Parameters) -> Double {
        let delta = -(p.w[6] * (Double(r.rawValue) - 3))
        let damped = d + (10 - d) * delta / 9
        let reverted = p.w[7] * initialDifficulty(.easy, clamp: false, p) + (1 - p.w[7]) * damped
        return clampDifficulty(reverted)
    }

    private static func nextStability(_ d: Double, _ s: Double, _ r: Double,
                                      _ rating: Rating, _ p: Parameters) -> Double {
        let next: Double
        if rating == .again {
            let longTerm = p.w[11] * pow(d, -p.w[12]) * (pow(s + 1, p.w[13]) - 1) * exp((1 - r) * p.w[14])
            let shortTerm = s / exp(p.w[17] * p.w[18])
            next = min(longTerm, shortTerm)
        } else {
            let hardPenalty = rating == .hard ? p.w[15] : 1
            let easyBonus = rating == .easy ? p.w[16] : 1
            next = s * (1 + exp(p.w[8]) * (11 - d) * pow(s, -p.w[9]) * (exp((1 - r) * p.w[10]) - 1)
                        * hardPenalty * easyBonus)
        }
        return max(next, stabilityMin)
    }

    private static func clampDifficulty(_ d: Double) -> Double { min(max(d, 1), 10) }

    /// Les jours pleins écoulés, comme `timedelta.days` en Python : arrondi vers le
    /// bas, pas des jours calendaires.
    private static func wholeDays(from a: Date, to b: Date) -> Int {
        Int((b.timeIntervalSince(a) / day).rounded(.down))
    }
}
