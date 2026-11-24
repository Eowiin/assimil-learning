import Foundation
import SwiftData

/// Ce que la révision du vocabulaire propose, et ce qu'elle fait aux cartes. Logique
/// testée (`VocabStudyTests`) ; l'écran (`VocabReviewView`) ne fait qu'afficher.
///
/// Une carte de mot n'existe en base qu'à partir de sa première note : tant qu'elle
/// n'a jamais été vue, c'est une « nouvelle » (`NewCard`), calculée depuis le
/// vocabulaire du paquet. Le plafond du jour compte donc les cartes créées
/// aujourd'hui.
///
/// Deux sources dans la même file : les mots d'Assimil (paquet `assimil-es`) et ceux
/// du lexique adaptatif vus dans le texte du bloc 2 (`lexique-es`, `LexiconWords`).
@MainActor
enum VocabStudy {

    /// Au plus 20 nouvelles cartes par jour (décision du cadrage).
    static let newPerDay = 20
    /// Au plus 10 cartes par cycle de la séance adaptative (étape 5a) : une grosse file
    /// se répartit sur les cycles au lieu de remplir le premier. La révision ouverte
    /// depuis l'accueil, elle, n'a pas de plafond.
    static let perCycle = 10
    /// Une carte en apprentissage due dans moins de 20 minutes est proposée tout de
    /// suite quand il ne reste rien d'autre, comme dans Anki : sinon la séance
    /// finirait avec des cartes qui reviennent dans dix minutes.
    static let learnAhead: TimeInterval = 20 * 60

    /// Le paquet des cartes du lexique adaptatif : un mot vu dans le texte du bloc 2.
    /// À part d'Assimil, pour qu'un même lemme n'y soit pas pris pour l'autre.
    nonisolated static let lexiconPack = "lexique-es"

    /// Une carte qui n'existe pas encore.
    struct NewCard: Hashable {
        let item: VocabItem
        let angle: String
        var pack: String = PackStore.assimilSpanishID
        var key: String { Card.makeKey(item: item.itemID(pack: pack), angle: angle) }
        var isLexicon: Bool { pack == VocabStudy.lexiconPack }
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
    ///
    /// Une carte dont le mot n'est plus dans le vocabulaire (« tal », absorbé par
    /// « qué tal ») est orpheline : écartée, pas supprimée — son journal reste.
    static func due(_ cards: [Card], in vocabulary: Vocabulary, lexicon: LexiconWords = .empty, now: Date,
                    calendar: Calendar = .current) -> [Card] {
        let endOfToday: Date = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let due: [Card] = cards.filter { card in
            guard card.isActive, card.scheduler == Card.Scheduler.fsrs,
                  isInVocabulary(card, vocabulary, lexicon) else { return false }
            return card.isInReview ? card.dueAt < endOfToday : card.dueAt <= now
        }
        return due.sorted { a, b in a.dueAt == b.dueAt ? a.key < b.key : a.dueAt < b.dueAt }
    }

    /// Les cartes en apprentissage qui reviennent dans la séance (moins de 20 minutes).
    static func dueSoon(_ cards: [Card], in vocabulary: Vocabulary, lexicon: LexiconWords = .empty,
                        now: Date) -> [Card] {
        cards.filter {
            $0.isActive && $0.scheduler == Card.Scheduler.fsrs && !$0.isInReview
                && $0.dueAt > now && $0.dueAt <= now.addingTimeInterval(learnAhead)
                && isInVocabulary($0, vocabulary, lexicon)
        }
        .sorted { $0.dueAt < $1.dueAt }
    }

    /// Une carte d'Assimil dont le mot est au vocabulaire, ou une carte du lexique dont
    /// la phrase est connue. Une autre est orpheline.
    private static func isInVocabulary(_ card: Card, _ vocabulary: Vocabulary, _ lexicon: LexiconWords) -> Bool {
        guard let id = ItemID(card.itemID), let item = VocabItem(id) else { return false }
        switch id.pack {
        case PackStore.assimilSpanishID: return vocabulary.word(item) != nil
        case lexiconPack: return lexicon.word(item.lemma) != nil
        default: return false
        }
    }

    /// Combien de nouvelles cartes sont encore permises aujourd'hui.
    static func newRemaining(_ cards: [Card], now: Date, calendar: Calendar = .current) -> Int {
        let startOfToday = calendar.startOfDay(for: now)
        let introduced = cards.filter { $0.scheduler == Card.Scheduler.fsrs && $0.createdAt >= startOfToday }.count
        return max(0, newPerDay - introduced)
    }

    /// Les prochaines nouvelles cartes. D'abord les mots du texte du bloc 2, dans
    /// l'ordre où ils ont été vus : une seule carte chacun, `recognize` (la phrase au
    /// recto). Puis ceux d'Assimil, dans l'ordre du livre (première leçon, puis
    /// fréquence) : sa carte `recognize` s'il n'en a pas ; sa carte `recall` une fois
    /// la première connue. Un mot retiré a ses cartes inactives : il ne revient pas.
    static func newCards(vocabulary: Vocabulary, lessons: Set<Int>, cards: [Card], limit: Int,
                         lexicon: LexiconWords = .empty, calendar: Calendar = .current) -> [NewCard] {
        guard limit > 0 else { return [] }
        let byKey = Dictionary(cards.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [NewCard] = []
        for word in lexicon.words {
            guard let item = VocabItem(lemma: word.lemma) else { continue }
            let new = NewCard(item: item, angle: Card.Angle.recognize, pack: lexiconPack)
            if byKey[new.key] == nil { result.append(new) }
            if result.count == limit { return result }
        }
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
        let card = Card(item: new.item.itemID(pack: new.pack), angle: new.angle, language: "es",
                        scheduler: Card.Scheduler.fsrs, at: date)
        context.insert(card)
        return card
    }

    /// « Retirer ce mot » : ses deux cartes deviennent inactives, créées au besoin
    /// pour que le mot ne soit plus proposé. Rien n'est supprimé.
    static func retire(_ item: VocabItem, pack: String = PackStore.assimilSpanishID, cards: [Card],
                       at date: Date, in context: ModelContext) {
        for angle in [Card.Angle.recognize, Card.Angle.recall] {
            let key = Card.makeKey(item: item.itemID(pack: pack), angle: angle)
            if let card = cards.first(where: { $0.key == key }) {
                card.isActive = false
            } else {
                introduce(NewCard(item: item, angle: angle, pack: pack), at: date, in: context).isActive = false
            }
        }
    }

    /// Une carte notée qui devient connue fait monter son mot dans le lexique
    /// adaptatif (`docs/moteur-adaptatif.md`) : `recognize` connue, reconnu ;
    /// `recall` connue, actif. Le mot entre dans l'état s'il n'y était pas.
    static func noteKnowledge(of card: Card, ranks: [String: Int], at date: Date,
                              calendar: Calendar = .current, in context: ModelContext) {
        guard card.isActive, card.isKnown(calendar: calendar),
              let id = ItemID(card.itemID), let item = VocabItem(id) else { return }
        let status: String
        switch card.angle {
        case Card.Angle.recognize: status = LexemeState.Status.recognized
        case Card.Angle.recall: status = LexemeState.Status.active
        default: return
        }
        let language = card.language
        let key = AdaptiveKey.make(language: language, item.lemma)
        let state = (try? context.fetch(FetchDescriptor<LexemeState>(predicate: #Predicate { $0.key == key })))?.first
            ?? {
                let source = id.pack == lexiconPack ? LexiconWords.source : LexiconMigration.source
                let created = LexemeState(language: language, lemma: item.lemma, rank: ranks[item.lemma],
                                          source: source, at: date)
                context.insert(created)
                return created
            }()
        state.raise(to: status, at: date)
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

        var pack: String? {
            switch self {
            case .card(let card): ItemID(card.itemID)?.pack
            case .new(let new): new.pack
            }
        }

        /// Un mot vu dans le texte du bloc 2 : sa carte montre la phrase.
        var isLexicon: Bool { pack == VocabStudy.lexiconPack }

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

    /// `limit` borne le nombre de cartes de la séance : celles en apprentissage qui
    /// reviennent d'abord (elles sont entamées), puis les dues, puis les nouvelles. Une
    /// carte qui repasse dans la séance ne compte qu'une fois.
    init(due: [Card], new: [VocabStudy.NewCard], soon: [Card] = [], limit: Int? = nil) {
        let entries = due.map(Entry.card) + new.map(Entry.new)
        guard let limit else {
            pending = entries
            waiting = soon
            return
        }
        waiting = Array(soon.prefix(max(0, limit)))
        pending = Array(entries.prefix(max(0, limit - waiting.count)))
    }

    /// Combien de cartes une séance bornée à `limit` montrera : ce que dit le bloc 1.
    static func capped(due: Int, new: Int, limit: Int) -> (due: Int, new: Int) {
        let shownDue = min(due, max(0, limit))
        return (shownDue, min(new, max(0, limit - shownDue)))
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

    /// Un mot retiré : ses autres cartes quittent aussi la séance. Le même lemme dans
    /// l'autre source reste.
    mutating func drop(_ item: VocabItem, pack: String = PackStore.assimilSpanishID) {
        pending.removeAll { $0.item == item && $0.pack == pack }
        waiting.removeAll { $0.vocabItem == item && ItemID($0.itemID)?.pack == pack }
    }
}

/// Les mots du lexique adaptatif qui ont leur phrase (vus dans le texte du bloc 2) :
/// de quoi faire leurs cartes, dans l'ordre où ils ont été vus.
struct LexiconWords {
    struct Word: Equatable {
        let lemma: String
        let sentence: String
        let form: String?
        let translation: String
    }

    /// La source d'un mot entré dans l'état par le texte du bloc 2.
    static let source = "input"
    static let empty = LexiconWords(words: [])

    let words: [Word]
    private let byLemma: [String: Word]

    init(words: [Word]) {
        self.words = words
        byLemma = Dictionary(words.map { ($0.lemma, $0) }, uniquingKeysWith: { first, _ in first })
    }

    init(states: [LexemeState], language: String = "es") {
        self.init(words: states
            .filter { $0.language == language && $0.hasContext }
            .sorted { $0.firstSeenAt == $1.firstSeenAt ? $0.lemma < $1.lemma : $0.firstSeenAt < $1.firstSeenAt }
            .map { Word(lemma: $0.lemma, sentence: $0.contextES ?? "", form: $0.contextForm,
                        translation: $0.contextFR ?? "") })
    }

    func word(_ lemma: String) -> Word? { byLemma[lemma] }
}
