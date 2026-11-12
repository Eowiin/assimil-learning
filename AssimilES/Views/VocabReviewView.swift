import SwiftUI
import SwiftData

/// La révision des mots, à la Anki : le recto, « Voir la réponse », le verso (sens,
/// phrase de la leçon et son audio), puis une note parmi quatre. La règle vit dans
/// `VocabStudy` et `CardReview.grade` ; l'écran affiche et transmet.
struct VocabReviewView: View {
    let vocabulary: Vocabulary
    let lessons: Set<Int>

    @Environment(\.modelContext) private var context
    @Environment(\.manifest) private var manifest
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var player: SessionPlayer
    @Query private var cards: [Card]

    @State private var session: VocabSession?
    @State private var showAnswer = false
    @State private var shownAt = DayClock.systemNow()
    /// Secondes d'étude pas encore inscrites (`StudyTime`).
    @State private var unrecorded: Double = 0

    /// Une carte regardée plus d'une minute compte pour une minute : le téléphone
    /// posé ne fait pas du temps d'étude (même plafond qu'Anki).
    private static let maxSecondsPerCard: Double = 60

    var body: some View {
        Group {
            if let session, let entry = session.current, let item = entry.item, let word = vocabulary.word(item) {
                card(entry, word: word, remaining: session.remaining)
            } else if session != nil {
                done
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyStyle.paper)
        .navigationTitle("Vocabulaire")
        .navigationBarTitleDisplayMode(.inline)
        // Comme pendant une séance : les notes sont au pouce, la barre d'onglets
        // les serrerait.
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbar }
        .onAppear(perform: start)
        .onDisappear {
            player.pause()
            recordTime()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { recordTime() }
            if scenePhase == .active { shownAt = DayClock.systemNow() }
        }
    }

    // MARK: - La carte

    private func card(_ entry: VocabSession.Entry, word: Vocabulary.Word, remaining: Int) -> some View {
        let recall = entry.angle == Card.Angle.recall
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    Text(recall ? "En espagnol ?" : "Que veut dire… ?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 28)
                    Text(recall ? (word.translation ?? word.lemma) : word.lemma)
                        .font(.system(.largeTitle, design: .serif).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("vocab-front")
                    if case .new = entry {
                        Text("Nouveau")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(StudyStyle.surface, in: Capsule())
                    }
                    if showAnswer {
                        Divider().padding(.horizontal, 40)
                        answer(word, recall: recall)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            controls(entry)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .animation(.default, value: showAnswer)
    }

    private func answer(_ word: Vocabulary.Word, recall: Bool) -> some View {
        VStack(spacing: 14) {
            Text(recall ? word.lemma : (word.translation ?? "—"))
                .font(.title.weight(.medium))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("vocab-back")
            let others = word.forms.filter { $0 != word.lemma }
            if !others.isEmpty {
                Text(others.prefix(6).joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let example = example(word) {
                exampleView(example)
            }
        }
    }

    /// La première phrase où le mot apparaît et dont le texte existe : c'est elle qui
    /// donne le sens, la traduction ne fait qu'aider.
    private func example(_ word: Vocabulary.Word) -> (Vocabulary.Occurrence, SentenceText)? {
        for occurrence in word.occurrences {
            let text = LessonTextStore.text(for: occurrence.lesson)
            let line = occurrence.isExercise ? text?.exerciseSentence(occurrence.n) : text?.sentence(occurrence.n)
            if let line { return (occurrence, line) }
        }
        return nil
    }

    private func exampleView(_ example: (Vocabulary.Occurrence, SentenceText)) -> some View {
        let (occurrence, line) = example
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(line.es).font(.body)
                // Le français du livre s'il existe (leçons 1 à 5), sinon la traduction
                // automatique, dite comme telle : c'est la phrase qui donne le sens.
                if let fr = line.fr, !fr.isEmpty {
                    Text(fr).font(.callout).foregroundStyle(.secondary)
                } else if let fr = vocabulary.sentenceTranslation(occurrence.item) {
                    Text(fr).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vocab-example-fr")
                    Text("Traduction automatique").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("Leçon \(occurrence.lesson)\(occurrence.isExercise ? ", exercice" : "")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { play(occurrence) } label: {
                Image(systemName: "speaker.wave.2").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyStyle.accent)
            .accessibilityLabel("Écouter la phrase")
            .accessibilityIdentifier("vocab-play")
        }
        .padding(14)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func controls(_ entry: VocabSession.Entry) -> some View {
        if showAnswer {
            let preview = previewDates(entry)
            HStack(spacing: 8) {
                ForEach(FSRS.Rating.allCases, id: \.self) { rating in
                    Button { grade(entry, rating) } label: {
                        VStack(spacing: 2) {
                            Text(Self.label(rating)).font(.subheadline.weight(.semibold))
                            if let date = preview[rating] {
                                Text(Self.delay(from: DayClock.systemNow(), to: date))
                                    .font(.caption2).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .tint(rating == .again ? .orange : StudyStyle.accent)
                    .accessibilityIdentifier("vocab-rate-\(rating.rawValue)")
                }
            }
        } else {
            Button { showAnswer = true } label: {
                Text("Voir la réponse").frame(maxWidth: .infinity)
            }
            .buttonStyle(StudyPrimaryButtonStyle())
            .accessibilityIdentifier("vocab-show")
        }
    }

    private var done: some View {
        ContentUnavailableView {
            Label("C'est tout pour aujourd'hui", systemImage: "checkmark.circle")
        } description: {
            Text("Les mots reviendront quand il sera temps de les revoir.")
        }
        .accessibilityIdentifier("vocab-done")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let session, session.current != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { retireCurrent() } label: {
                        Label("Retirer ce mot", systemImage: "minus.circle")
                    }
                } label: {
                    Label("\(session.remaining)", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("vocab-menu")
                .accessibilityLabel("\(session.remaining) cartes restantes, options")
            }
        }
    }

    // MARK: - Gestes

    private func start() {
        shownAt = DayClock.systemNow()
        guard session == nil else { return }
        let now = DayClock.systemNow()
        VocabStudy.applyRenames(vocabulary.renamed, cards: cards, in: context)
        let new = VocabStudy.newCards(vocabulary: vocabulary, lessons: lessons, cards: cards,
                                      limit: VocabStudy.newRemaining(cards, now: now))
        var s = VocabSession(due: VocabStudy.due(cards, in: vocabulary, now: now), new: new,
                             soon: VocabStudy.dueSoon(cards, in: vocabulary, now: now))
        s.advance(now: now)
        session = s
    }

    private func grade(_ entry: VocabSession.Entry, _ rating: FSRS.Rating) {
        let now = DayClock.systemNow()
        let seconds = min(now.timeIntervalSince(shownAt), Self.maxSecondsPerCard)
        let card: Card
        switch entry {
        case .card(let existing): card = existing
        case .new(let new): card = VocabStudy.introduce(new, at: now, in: context)
        }
        CardReview.grade(card, rating, at: now, durationMs: Int(seconds * 1000), in: context)
        try? context.save()
        unrecorded += seconds
        next(after: card, now: now)
    }

    private func retireCurrent() {
        guard let item = session?.current?.item else { return }
        let now = DayClock.systemNow()
        VocabStudy.retire(item, cards: cards, at: now, in: context)
        try? context.save()
        session?.drop(item)
        next(after: nil, now: now)
    }

    private func next(after card: Card?, now: Date) {
        player.pause()
        showAnswer = false
        session?.finishCurrent(with: card, now: now)
        shownAt = now
    }

    private func previewDates(_ entry: VocabSession.Entry) -> [FSRS.Rating: Date] {
        let now = DayClock.systemNow()
        switch entry {
        case .card(let card):
            return CardReview.preview(card, at: now)
        case .new:
            return Dictionary(uniqueKeysWithValues: FSRS.Rating.allCases.map {
                ($0, FSRS.review(.new(at: now), rating: $0, at: now).due)
            })
        }
    }

    private func play(_ occurrence: Vocabulary.Occurrence) {
        guard let lesson = manifest.lesson(occurrence.lesson),
              let clip = SessionBuilder.clip(for: occurrence.item, in: lesson)
        else { return }
        player.start(.excerpt(lessonNumber: lesson.number),
                     steps: SessionBuilder.excerpt(clip, isExercise: occurrence.isExercise, in: lesson, manifest: manifest))
    }

    /// Le temps de l'écran, plafonné par carte, et non le temps d'écoute du lecteur :
    /// les phrases écoutées ici en font partie.
    private func recordTime() {
        _ = player.takeUnrecordedSeconds()
        StudyTime.record(unrecorded, as: .vocab, in: context)
        unrecorded = 0
        try? context.save()
    }

    // MARK: - Libellés

    static func label(_ rating: FSRS.Rating) -> String {
        switch rating {
        case .again: "À revoir"
        case .hard: "Difficile"
        case .good: "Bien"
        case .easy: "Facile"
        }
    }

    /// « 1 min », « 10 min », « 3 j », « 2 mois », « 1 an » : l'ordre de grandeur,
    /// comme sous les boutons d'Anki.
    static func delay(from now: Date, to date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded())
        let days = Int((seconds / 86_400).rounded())
        switch seconds {
        case ..<3600: return "\(max(1, minutes)) min"
        case ..<86_400: return "\(Int((seconds / 3600).rounded())) h"
        case ..<(30 * 86_400): return "\(days) j"
        case ..<(365 * 86_400): return "\(Int((Double(days) / 30).rounded())) mois"
        default:
            let years = Double(days) / 365
            return years < 10 ? String(format: "%.1f an", years).replacingOccurrences(of: ".", with: ",")
                : "\(Int(years.rounded())) ans"
        }
    }
}
