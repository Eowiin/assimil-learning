import Foundation
import Testing
@testable import AssimilES

/// FSRS contre l'implémentation officielle. Les valeurs attendues viennent de py-fsrs
/// 6.3.2, sans fuzz, par `tools/vocabulaire/fsrs-reference.py` : relancer le script
/// et recoller sa sortie si les scénarios changent.
@Suite("FSRS, contre py-fsrs")
struct FSRSTests {

    struct Expected {
        let rating: Int
        /// Secondes depuis la revue précédente (ou la création de la carte).
        let after: TimeInterval
        let state: FSRS.State
        let step: Int?
        let stability: Double
        let difficulty: Double
        /// Secondes entre la revue et la prochaine échéance.
        let dueIn: TimeInterval
    }

    static let scenarios: [(String, [Expected])] = [
    // toutBien
    ("toutBien", [
        Expected(rating: 3, after: 0, state: .learning, step: 1, stability: 2.3065, difficulty: 2.118103970459016, dueIn: 600.0),
        Expected(rating: 3, after: 60, state: .review, step: nil, stability: 2.3065, difficulty: 2.111214235785395, dueIn: 172800.0),
        Expected(rating: 3, after: 259200, state: .review, step: nil, stability: 13.835840133660218, difficulty: 2.1043313908464483, dueIn: 1209600.0),
        Expected(rating: 3, after: 691200, state: .review, step: nil, stability: 42.09439066926473, difficulty: 2.0974554287524403, dueIn: 3628800.0),
        Expected(rating: 3, after: 1814400, state: .review, step: nil, stability: 105.53214678722775, difficulty: 2.0905863426205262, dueIn: 9158400.0),
    ]),
    // facileDEmblee
    ("facileDEmblee", [
        Expected(rating: 4, after: 0, state: .review, step: nil, stability: 8.2956, difficulty: 1.0, dueIn: 691200.0),
        Expected(rating: 4, after: 691200, state: .review, step: nil, stability: 65.62422616189994, difficulty: 1.0, dueIn: 5702400.0),
        Expected(rating: 4, after: 2592000, state: .review, step: nil, stability: 245.41909179849148, difficulty: 1.0, dueIn: 21168000.0),
    ]),
    // oubliPuisReapprentissage
    ("oubliPuisReapprentissage", [
        Expected(rating: 3, after: 0, state: .learning, step: 1, stability: 2.3065, difficulty: 2.118103970459016, dueIn: 600.0),
        Expected(rating: 3, after: 600, state: .review, step: nil, stability: 2.3065, difficulty: 2.111214235785395, dueIn: 172800.0),
        Expected(rating: 3, after: 172800, state: .review, step: nil, stability: 10.971048263078135, difficulty: 2.1043313908464483, dueIn: 950400.0),
        Expected(rating: 1, after: 432000, state: .relearning, step: 0, stability: 1.4294146465512396, difficulty: 7.389975788014609, dueIn: 600.0),
        Expected(rating: 3, after: 600, state: .review, step: nil, stability: 1.4670197822758384, difficulty: 7.377814181523433, dueIn: 86400.0),
        Expected(rating: 3, after: 86400, state: .review, step: nil, stability: 3.4854020110429205, difficulty: 7.365664736638748, dueIn: 259200.0),
        Expected(rating: 2, after: 259200, state: .review, step: nil, stability: 6.474572678700652, difficulty: 8.236433861454366, dueIn: 518400.0),
    ]),
    // difficileEnApprentissage
    ("difficileEnApprentissage", [
        Expected(rating: 2, after: 0, state: .learning, step: 0, stability: 1.2931, difficulty: 5.112170705601056, dueIn: 330.0),
        Expected(rating: 2, after: 300, state: .learning, step: 0, stability: 1.2931, difficulty: 6.7404595108297, dueIn: 330.0),
        Expected(rating: 3, after: 600, state: .learning, step: 1, stability: 1.3358997622047517, difficulty: 6.728947420615708, dueIn: 600.0),
        Expected(rating: 3, after: 600, state: .review, step: nil, stability: 1.3771622371865915, difficulty: 6.717446842491931, dueIn: 86400.0),
        Expected(rating: 1, after: 172800, state: .relearning, step: 0, stability: 0.4163665247996883, difficulty: 8.906275467785408, dueIn: 600.0),
        Expected(rating: 1, after: 300, state: .relearning, step: 0, stability: 0.15660006521172062, difficulty: 9.62572855288472, dueIn: 600.0),
        Expected(rating: 4, after: 120, state: .review, step: nil, stability: 0.3197912224986737, difficulty: 9.485892845605067, dueIn: 86400.0),
    ]),
    // enRetard
    ("enRetard", [
        Expected(rating: 3, after: 0, state: .learning, step: 1, stability: 2.3065, difficulty: 2.118103970459016, dueIn: 600.0),
        Expected(rating: 3, after: 600, state: .review, step: nil, stability: 2.3065, difficulty: 2.111214235785395, dueIn: 172800.0),
        Expected(rating: 3, after: 3456000, state: .review, step: nil, stability: 40.75022071577297, difficulty: 2.1043313908464483, dueIn: 3542400.0),
        Expected(rating: 2, after: 7776000, state: .review, step: nil, stability: 146.4975245414879, difficulty: 4.743715608383524, dueIn: 12614400.0),
    ]),
    // memeJourEnRevision
    ("memeJourEnRevision", [
        Expected(rating: 4, after: 0, state: .review, step: nil, stability: 8.2956, difficulty: 1.0, dueIn: 691200.0),
        Expected(rating: 3, after: 3600, state: .review, step: nil, stability: 8.2956, difficulty: 1.0, dueIn: 691200.0),
        Expected(rating: 1, after: 3600, state: .relearning, step: 0, stability: 2.5625081682260777, difficulty: 7.0269895692968385, dueIn: 600.0),
        Expected(rating: 3, after: 600, state: .review, step: nil, stability: 2.5625081682260777, difficulty: 7.0151909490243805, dueIn: 259200.0),
    ]),
    ]

    @Test("Chaque scénario suit py-fsrs, revue par revue", arguments: scenarios.map(\.0))
    func matchesReference(_ name: String) throws {
        let expected = try #require(Self.scenarios.first { $0.0 == name }?.1)
        let start = Date(timeIntervalSince1970: 1_767_258_000) // 2026-01-01 09:00 UTC
        var memory = FSRS.Memory.new(at: start)
        var now = start
        for (i, e) in expected.enumerated() {
            now = now.addingTimeInterval(e.after)
            memory = FSRS.review(memory, rating: try #require(FSRS.Rating(rawValue: e.rating)), at: now)
            #expect(memory.state == e.state, "revue \(i + 1)")
            #expect(memory.step == e.step, "revue \(i + 1)")
            #expect(abs((memory.stability ?? -1) - e.stability) < 1e-9, "revue \(i + 1) : stabilité \(memory.stability ?? -1)")
            #expect(abs((memory.difficulty ?? -1) - e.difficulty) < 1e-9, "revue \(i + 1) : difficulté \(memory.difficulty ?? -1)")
            #expect(memory.due.timeIntervalSince(now) == e.dueIn, "revue \(i + 1) : échéance")
            #expect(memory.lastReview == now)
        }
    }

    @Test("Une carte neuve n'a aucune chance d'être retenue ; une carte revue, 90 % à l'échéance")
    func retrievability() {
        let start = Date(timeIntervalSince1970: 1_767_258_000)
        #expect(FSRS.retrievability(.new(at: start), at: start) == 0)
        let reviewed = FSRS.review(.new(at: start), rating: .easy, at: start)
        #expect(FSRS.retrievability(reviewed, at: start) == 1)
        // Huit jours : l'intervalle visé pour 90 % de rétention, arrondi au jour.
        let atDue = FSRS.retrievability(reviewed, at: reviewed.due)
        #expect(abs(atDue - 0.9) < 0.01)
    }
}
