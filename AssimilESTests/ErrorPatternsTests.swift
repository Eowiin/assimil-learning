import Foundation
import Testing
@testable import AssimilES

private func fault(_ said: String, tag: String?, category: ConversationCorrection.Category? = .grammar) -> ConversationCorrection {
    ConversationCorrection(said: said, corrected: said + " (corrigé)", explanation: "", category: category, tag: tag)
}

private func conversation(day: Double, _ corrections: [ConversationCorrection]) -> ErrorPatterns.Conversation {
    ErrorPatterns.Conversation(endedAt: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400),
                               corrections: corrections)
}

@Suite("Profil : les fautes de conversation qui reviennent")
struct ErrorPatternsTests {

    @Test("Le même point, écrit autrement par l'IA, est un seul point")
    func grouping() {
        #expect(ErrorPatterns.key("Ser/Estar") == ErrorPatterns.key("ser / estar"))
        #expect(ErrorPatterns.key("Accord du verbe") == ErrorPatterns.key("accord du verbe"))
        #expect(ErrorPatterns.key("por/pára") == ErrorPatterns.key("por/para"))
        #expect(ErrorPatterns.key("ser/estar") != ErrorPatterns.key("por/para"))
        #expect(ErrorPatterns.key("  ") == nil)
    }

    @Test("Compté par conversation, pas par phrase ; le dernier nom écrit est gardé")
    func countByConversation() {
        let patterns = ErrorPatterns(conversations: [
            conversation(day: 1, [fault("Yo soy cansado", tag: "Ser/Estar"), fault("Es en casa", tag: "ser / estar")]),
            conversation(day: 2, [fault("Soy contento", tag: "ser/estar"), fault("Por mí", tag: "por/para")]),
        ])
        let serEstar = patterns.pattern(for: fault("x", tag: "SER/ESTAR"))
        #expect(serEstar?.conversations == 2)
        #expect(serEstar?.tag == "ser/estar")
        #expect(serEstar?.examples.map(\.said) == ["Soy contento", "Es en casa", "Yo soy cansado"])
        #expect(patterns.pattern(for: fault("x", tag: "por/para"))?.conversations == 1)
        #expect(patterns.mostFrequent.map(\.tag) == ["ser/estar", "por/para"])
    }

    @Test("Trois exemples au plus, le plus récent d'abord")
    func examples() {
        let patterns = ErrorPatterns(conversations: (1...5).map { day in
            conversation(day: Double(day), [fault("phrase \(day)", tag: "gustar")])
        }.shuffled())
        #expect(patterns.pattern(for: fault("x", tag: "gustar"))?.examples.map(\.said)
                == ["phrase 5", "phrase 4", "phrase 3"])
    }

    @Test("Une correction gardée avant les étiquettes n'est comptée nulle part")
    func untagged() {
        let patterns = ErrorPatterns(conversations: [conversation(day: 1, [fault("Yo soy cansado", tag: nil)])])
        #expect(patterns.patterns.isEmpty)
        #expect(patterns.pattern(for: fault("Yo soy cansado", tag: nil)) == nil)
    }

    @Test("Lu depuis les conversations gardées ; une conversation sans récapitulatif ne compte pas")
    func fromRecords() {
        let reviewed = ConversationRecord(startedAt: .now, endedAt: .now, messages: [])
        reviewed.reviewedCorrections = [fault("Yo soy cansado", tag: "ser/estar")]
        let pending = ConversationRecord(startedAt: .now, endedAt: .now, messages: [])
        let patterns = ErrorPatterns(records: [reviewed, pending])
        #expect(patterns.pattern(for: fault("x", tag: "ser/estar"))?.conversations == 1)
    }

    @Test("Le récapitulatif dit qu'une faute revient, et rien pour une première faute")
    func recapLine() {
        let earlier = ErrorPatterns(conversations: [
            conversation(day: 1, [fault("Yo soy cansado", tag: "ser/estar")]),
            conversation(day: 2, [fault("Soy contento", tag: "ser/estar"), fault("Me gusta los perros", tag: "gustar")]),
        ])
        #expect(ConversationRecapView.recurrence(of: fault("Es en casa", tag: "Ser/Estar"), in: earlier)
                == "Ser/Estar — déjà relevé dans 2 conversations")
        #expect(ConversationRecapView.recurrence(of: fault("Me gusta las flores", tag: "gustar"), in: earlier)
                == "gustar — déjà relevé dans une conversation")
        #expect(ConversationRecapView.recurrence(of: fault("Por mí", tag: "por/para"), in: earlier) == nil)
        #expect(ConversationRecapView.recurrence(of: fault("Por mí", tag: nil), in: earlier) == nil)
    }
}

@Suite("Profil : ce que reçoit le partenaire de conversation")
struct ConversationProfileTests {

    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + n * 86_400) }

    /// Une carte de mot ; `known` : en révision, réussie un autre jour que sa création.
    private func card(_ lemma: String, _ angle: String, known: Bool, reviewed: Double = 5,
                      active: Bool = true) -> Card {
        let card = Card(item: VocabItem(lemma: lemma)!.itemID(), angle: angle, language: "es",
                        scheduler: Card.Scheduler.fsrs, at: day(0))
        card.isActive = active
        card.fsrsState = known ? FSRS.State.review.rawValue : FSRS.State.learning.rawValue
        card.lastReviewedAt = day(reviewed)
        return card
    }

    private let none = ErrorPatterns(conversations: [])

    @Test("Les mots compris mais pas encore dits, les plus frais d'abord, cinq au plus")
    func words() {
        let cards = [
            card("aprovechar", Card.Angle.recognize, known: true, reviewed: 9),
            card("quedar con", Card.Angle.recognize, known: true, reviewed: 8),
            card("quedar con", Card.Angle.recall, known: false),
            card("trabajo", Card.Angle.recognize, known: true),           // déjà dit : exclu
            card("trabajo", Card.Angle.recall, known: true),
            card("agobiado", Card.Angle.recognize, known: false),         // pas encore compris
            card("de momento", Card.Angle.recognize, known: true, active: false),
        ] + (1...5).map { card("palabra\($0)", Card.Angle.recognize, known: true, reviewed: Double($0)) }
        let profile = ConversationProfile.make(patterns: none, cards: cards, calendar: calendar)
        #expect(profile?.words == ["aprovechar", "quedar con", "palabra5", "palabra4", "palabra3"])
        #expect(profile?.watch == nil)
    }

    @Test("La faute à surveiller revient dans deux conversations au moins")
    func watch() {
        let once = ErrorPatterns(conversations: [conversation(day: 1, [fault("a", tag: "por/para")])])
        #expect(ConversationProfile.make(patterns: once, cards: [], calendar: calendar) == nil)
        let twice = ErrorPatterns(conversations: [
            conversation(day: 1, [fault("a", tag: "por/para"), fault("b", tag: "ser/estar")]),
            conversation(day: 2, [fault("c", tag: "ser/estar")]),
        ])
        #expect(ConversationProfile.make(patterns: twice, cards: [], calendar: calendar)
                == ConversationProfile(watch: "ser/estar", words: []))
    }
}
