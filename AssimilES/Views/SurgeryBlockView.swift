import SwiftUI
import SwiftData

/// Les parties du bloc 1, dans l'ordre. Une partie ouverte puis refermée est cochée.
enum SurgeryPart: String, CaseIterable, Identifiable, Hashable {
    case reviews, microlesson, sounds

    var id: String { rawValue }
    /// La clé dans `StudyBlockProgress.parts`.
    var key: String { "\(StudyBlock.surgery.rawValue).\(rawValue)" }

    var title: String {
        switch self {
        case .reviews: "Révisions"
        case .microlesson: "Micro-leçon"
        case .sounds: "Tes sons faibles"
        }
    }

    var symbol: String {
        switch self {
        case .reviews: "character.book.closed"
        case .microlesson: "lightbulb"
        case .sounds: "mouth"
        }
    }
}

/// Le bloc 1, « Chirurgie » : les révisions du jour, la micro-leçon de l'objectif, puis
/// cinq phrases sur les sons faibles. Les révisions sont celles du vocabulaire (les mots
/// du lexique les rejoindront avec le texte du bloc 2) ; les sons, la séance de
/// prononciation centrée sur les sons les plus ratés.
struct SurgeryBlockContent: View {
    let session: StudySession
    let pack: CurriculumPack
    /// Une partie s'ouvre par-dessus le bloc : son temps n'est pas celui du bloc seul.
    let onOpen: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.manifest) private var manifest
    @Environment(ServerStatus.self) private var server
    @EnvironmentObject private var clock: DayClock
    @Query private var cards: [Card]
    @Query private var dailySessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @State private var openedPart: SurgeryPart?

    private var objective: CurriculumPack.Objective? { session.objectiveID.flatMap(pack.objective) }
    private var vocabulary: Vocabulary? { VocabularyStore.current }

    /// Les leçons dont les mots sont proposés, comme sur l'accueil.
    private var vocabLessons: Set<Int> {
        VocabStudy.availableLessons(sessions: dailySessions, anchorUnit: anchors.first?.unit,
                                    manifest: manifest, now: clock.today)
    }

    private var reviewCounts: (due: Int, new: Int) {
        guard let vocabulary else { return (0, 0) }
        let now = DayClock.systemNow()
        let new = VocabStudy.newCards(vocabulary: vocabulary, lessons: vocabLessons, cards: cards,
                                      limit: VocabStudy.newRemaining(cards, now: now)).count
        return (VocabStudy.due(cards, in: vocabulary, now: now).count, new)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(SurgeryPart.allCases) { part in row(part) }
        }
        .navigationDestination(item: $openedPart) { part in destination(part) }
        .onChange(of: openedPart) { old, new in
            // Refermée : la partie est faite.
            if new == nil, let old {
                StudySessionProgress.markPart(old.key, in: session, at: .now)
                try? context.save()
            }
        }
    }

    private func row(_ part: SurgeryPart) -> some View {
        let state = availability(part)
        let done = session.blocks.parts[part.key] != nil
        return Button {
            onOpen()
            openedPart = part
        } label: {
            HStack(spacing: 14) {
                Image(systemName: done ? "checkmark.circle.fill" : part.symbol)
                    .font(.title2)
                    .foregroundStyle(StudyStyle.accent)
                    .frame(width: 44, height: 44)
                    .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.title).font(.headline)
                    Text(state.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if state.openable {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.openable)
        .accessibilityIdentifier("surgery-\(part.rawValue)")
    }

    /// Ce que la partie propose aujourd'hui, et si elle peut s'ouvrir.
    private func availability(_ part: SurgeryPart) -> (detail: String, openable: Bool) {
        switch part {
        case .reviews:
            let counts = reviewCounts
            return counts.due + counts.new == 0
                ? ("Rien à revoir aujourd'hui", false)
                : (TodayView.vocabDetail(due: counts.due, new: counts.new), true)
        case .microlesson:
            return (objective?.title ?? "Aucun objectif aujourd'hui", objective != nil && pack.microlessons[objective!.id] != nil)
        case .sounds:
            return server.pronunciation == nil
                ? ("Le PC ne répond pas : cette partie attendra", false)
                : ("Cinq phrases, centrées sur les sons que tu rates", true)
        }
    }

    @ViewBuilder
    private func destination(_ part: SurgeryPart) -> some View {
        switch part {
        case .reviews:
            if let vocabulary { VocabReviewView(vocabulary: vocabulary, lessons: vocabLessons) }
        case .microlesson:
            if let objective, let lesson = pack.microlessons[objective.id] {
                MicroLessonView(objective: objective, lesson: lesson)
            }
        case .sounds:
            if let service = server.pronunciation {
                PronunciationEntry(service: service, lessons: PronunciationDrill.lessons(available: vocabLessons))
            }
        }
    }
}

/// La micro-leçon d'un objectif : quelques lignes en français, et trois exemples dont la
/// traduction se montre d'un appui.
struct MicroLessonView: View {
    let objective: CurriculumPack.Objective
    let lesson: CurriculumPack.MicroLesson

    @Environment(\.dismiss) private var dismiss
    @State private var revealed: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Objectif · \(objective.level)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(objective.title)
                        .font(.title2.weight(.bold))
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lesson.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(StudyStyle.accent).frame(width: 6, height: 6)
                            Text(line)
                        }
                    }
                }
                .accessibilityIdentifier("microlesson-lines")
                VStack(alignment: .leading, spacing: 12) {
                    Text("Exemples").font(.headline)
                    ForEach(Array(lesson.examples.enumerated()), id: \.offset) { index, example in
                        Button {
                            revealed.insert(index)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(example.es)
                                    .font(.system(.title3, design: .serif))
                                    .foregroundStyle(.primary)
                                if revealed.contains(index) {
                                    Text(example.fr).foregroundStyle(.secondary)
                                } else {
                                    Label("Traduction", systemImage: "eye")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Compris") { dismiss() }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .accessibilityIdentifier("microlesson-done")
            }
            .padding(20)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StudyStyle.paper)
        .navigationTitle("Micro-leçon")
        .navigationBarTitleDisplayMode(.inline)
    }
}
