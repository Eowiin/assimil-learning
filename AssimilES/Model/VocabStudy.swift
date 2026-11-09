import Foundation
import SwiftData

/// Ce que la révision du vocabulaire propose, et ce qu'elle fait aux cartes. Logique
/// testée (`VocabStudyTests`) ; l'écran (`VocabReviewView`) ne fait qu'afficher.
///
/// Une carte de mot n'existe en base qu'à partir de sa première note : tant qu'elle
/// n'a jamais été vue, c'est une « nouvelle » (`NewCard`), calculée depuis le
/// vocabulaire du paquet. Le plafond du jour compte donc les cartes créées
/// aujourd'hui.
@MainActor
enum VocabStudy {

    /// Au plus 20 nouvelles cartes par jour (décision du cadrage).
    static let newPerDay = 20
    /// Une carte en apprentissage due dans moins de 20 minutes est proposée tout de
    /// suite quand il ne reste rien d'autre, comme dans Anki : sinon la séance
    /// finirait avec des cartes qui reviennent dans dix minutes.
    static let learnAhead: TimeInterval = 20 * 60

    /// Une carte qui n'existe pas encore.
    struct NewCard: Hashable {
        let item: VocabItem
        let angle: String
        var key: String { Card.makeKey(item: item.itemID(), angle: angle) }
    }

    // MARK: - Les leçons dont les mots sont proposés

    /// Les leçons validées **avant aujourd'hui** : les mots de la leçon du jour
    /// arrivent le lendemain, une fois la leçon digérée. Plus celles d'avant le point
    /// de départ du parcours : elles ont été faites, simplement pas dans l'app.
    static func availableLessons(sessions: [DailySession], anchorUnit: Int?, manifest: Manifest,
                                 now: Date, calendar: Calendar = .current) -> Set<Int> {
        let startOfToday = calendar.startOfDay(for: now)
        var units = Set(sessions.compactMap { s in s.completedAt.flatMap { $0 < startOfToday ? s.unit : nil } })
        if let anchorUnit, anchorUnit > 1 { units.formUnion(1..<anchorUnit) }
        return Set(units.compactMap { Curriculum.plan(unit: $0, manifest: manifest)?.newLesson })
    }

    // MARK: - Ce qui est dû

    /// Les cartes de mots dues. Une carte en révision due ce soir l'est dès ce matin :
    /// la révision est quotidienne, l'heure n'a pas à décider. Une carte en
    /// apprentissage, elle, attend ses minutes.
    static func due(_ cards: [Card], now: Date, calendar: Calendar = .current) -> [Card] {
        let endOfToday: Date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let due: [Card] = cards.filter { card in
            guard card.isActive, card.scheduler == Card.Scheduler.fsrs else { return false }
            return card.isInReview ? card.dueAt < endOfToday : card.dueAt <= now
        }
        return due.sorted { a, b in a.dueAt == b.dueAt ? a.key < b.key : a.dueAt < b.dueAt }
    }

    /// Les cartes en apprentissage qui reviennent dans la séance (moins de 20 minutes).
    static func dueSoon(_ cards: [Card], now: Date) -> [Card] {
        cards.filter {
            $0.isActive && $0.scheduler == Card.Scheduler.fsrs && !$0.isInReview
                && $0.dueAt > now && $0.dueAt <= now.addingTimeInterval(learnAhead)
        }
        .sorted { $0.dueAt < $1.dueAt }
    }

    /// Combien de nouvelles cartes sont encore permises aujourd'hui.
    static func newRemaining(_ cards: [Card], now: Date, calendar: Calendar = .current) -> Int {
        let startOfToday = calendar.startOfDay(for: now)
        let introduced = cards.filter { $0.scheduler == Card.Scheduler.fsrs && $0.createdAt >= startOfToday }.count
        return max(0, newPerDay - introduced)
    }

    /// Les prochaines nouvelles cartes, dans l'ordre du livre (première leçon, puis
    /// fréquence). Pour un mot : sa carte `recognize` s'il n'en a pas ; sa carte
    /// `recall` une fois la première connue. Un mot retiré a ses deux cartes
    /// inactives : il ne revient pas.
    static func newCards(vocabulary: Vocabulary, lessons: Set<Int>, cards: [Card], limit: Int,
                         calendar: Calendar = .current) -> [NewCard] {
        guard limit > 0 else { return [] }
        let byKey = Dictionary(cards.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [NewCard] = []
        for word in vocabulary.words where lessons.contains(word.firstLesson) {
            guard let item = word.item else { continue }
            let recognize = NewCard(item: item, angle: Card.Angle.recognize)
            let recall = NewCard(item: item, angle: Card.Angle.recall)
            if let known = byKey[recognize.key] {
                if known.isActive, known.isKnown(calendar: calendar), byKey[recall.key] == nil { result.append(recall) }
            } else {
                result.append(recognize)
            }
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Gestes

    /// La première note d'une nouvelle carte la crée.
    @discardableResult
    static func introduce(_ new: NewCard, at date: Date, in context: ModelContext) -> Card {
        let card = Card(item: new.item.itemID(), angle: new.angle, language: "es",
                        scheduler: Card.Scheduler.fsrs, at: date)
        context.insert(card)
        return card
    }

    /// « Retirer ce mot » : ses deux cartes deviennent inactives, créées au besoin
    /// pour que le mot ne soit plus proposé. Rien n'est supprimé.
    static func retire(_ item: VocabItem, cards: [Card], at date: Date, in context: ModelContext) {
        for angle in [Card.Angle.recognize, Card.Angle.recall] {
            let key = Card.makeKey(item: item.itemID(), angle: angle)
            if let card = cards.first(where: { $0.key == key }) {
                card.isActive = false
            } else {
                introduce(NewCard(item: item, angle: angle), at: date, in: context).isActive = false
            }
        }
    }

    /// Une forme de base corrigée dans le paquet (`Vocabulary.renamed`) : les cartes
    /// posées sur l'ancienne passent sur la nouvelle, historique compris. Si la
    /// nouvelle a déjà sa carte, l'ancienne est désactivée plutôt que fusionnée.
    /// Rend le nombre de cartes touchées.
    @discardableResult
    static func applyRenames(_ renamed: [String: String], cards: [Card], in context: ModelContext) -> Int {
        guard !renamed.isEmpty else { return 0 }
        var keys = Set(cards.map(\.key))
        var touched = 0
        for card in cards where card.scheduler == Card.Scheduler.fsrs {
            guard let old = card.vocabItem, let target = renamed[old.lemma],
                  let item = VocabItem(lemma: target) else { continue }
            let newKey = Card.makeKey(item: item.itemID(), angle: card.angle)
            if keys.contains(newKey) {
                card.isActive = false
            } else {
                let oldKey = card.key
                card.key = newKey
                card.itemID = item.itemID().rawValue
                keys.remove(oldKey)
                keys.insert(newKey)
                // Le journal suit la carte : il est la source de vérité.
                let logs = (try? context.fetch(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.cardKey == oldKey }))) ?? []
                logs.forEach { $0.cardKey = newKey }
            }
            touched += 1
        }
        return touched
    }
}

/// La file d'une séance de vocabulaire : les cartes dues, puis les nouvelles. Une
/// carte notée qui revient dans moins de 20 minutes (apprentissage) repasse dans la
/// même séance, quand son heure est venue — ou plus tôt s'il ne reste qu'elle.
@MainActor
struct VocabSession {
    enum Entry {
        case card(Card)
        case new(VocabStudy.NewCard)

        var item: VocabItem? {
            switch self {
            case .card(let card): card.vocabItem
            case .new(let new): new.item
            }
        }

        var angle: String {
            switch self {
            case .card(let card): card.angle
            case .new(let new): new.angle
            }
        }
    }

    private(set) var pending: [Entry]
    private(set) var waiting: [Card] = []
    private(set) var current: Entry?

    init(due: [Card], new: [VocabStudy.NewCard], soon: [Card] = []) {
        pending = due.map(Entry.card) + new.map(Entry.new)
        waiting = soon
    }

    /// Ce qui reste à voir, la carte en cours comprise.
    var remaining: Int { pending.count + waiting.count + (current == nil ? 0 : 1) }

    /// Passe à la carte suivante : une carte en attente dont l'heure est venue, sinon
    /// la file, sinon la plus proche des cartes en attente.
    mutating func advance(now: Date) {
        if let i = waiting.firstIndex(where: { $0.dueAt <= now }) {
            current = .card(waiting.remove(at: i))
        } else if !pending.isEmpty {
            current = pending.removeFirst()
        } else if let i = waiting.indices.min(by: { waiting[$0].dueAt < waiting[$1].dueAt }) {
            current = .card(waiting.remove(at: i))
        } else {
            current = nil
        }
    }

    /// La carte en cours vient d'être notée (ou retirée) : elle revient dans la
    /// séance si elle est due dans moins de 20 minutes.
    mutating func finishCurrent(with card: Card?, now: Date) {
        if let card, card.isActive, card.dueAt <= now.addingTimeInterval(VocabStudy.learnAhead) {
            waiting.append(card)
        }
        current = nil
        advance(now: now)
    }

    /// Un mot retiré : ses autres cartes quittent aussi la séance.
    mutating func drop(_ item: VocabItem) {
        pending.removeAll { $0.item == item }
        waiting.removeAll { $0.vocabItem == item }
    }
}
