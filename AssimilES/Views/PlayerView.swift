import SwiftUI
import SwiftData
import UIKit

/// L'écran de lecture : le texte de la séance, la phrase en cours surlignée, et
/// des commandes assez grosses pour être atteintes au pouce en marchant.
///
/// Tout ce qui s'affiche est dérivé des **étapes** de la séance, jamais d'une
/// leçon supposée unique : c'est ce qui permet au même écran de suivre une leçon,
/// la vague (deux leçons) ou la file de révision (autant de leçons qu'il y a de
/// phrases marquées).
struct PlayerView: View {
    let request: SessionRequest

    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context

    @Query private var marks: [DifficultSentence]
    @Query private var progress: [LessonProgress]

    @State private var showTranslation = false
    /// La phrase sur laquelle on veut s'essayer. Ouvre l'écran de prononciation.
    @State private var pronunciationStep: SessionStep?
    /// Étapes déjà comptées comme revues dans cette séance : rejouer une phrase
    /// ne doit pas repousser son échéance une seconde fois.
    @State private var reviewed: Set<UUID> = []

    private var markedKeys: Set<String> { Set(marks.map(\.key)) }
    private var isCurrentSession: Bool { player.request == request }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            controls
        }
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        // Pendant une séance, la barre d'onglets ne sert à rien et prend la
        // hauteur dont le texte a besoin.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Volontairement dans la barre du haut, pas dans les commandes du
            // bas : s'enregistrer suppose de s'arrêter, ce n'est pas un geste à
            // faire au pouce en marchant.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    pronunciationStep = player.currentNavigableStep
                } label: {
                    Label("Prononciation", systemImage: "mic")
                }
                .disabled(player.currentNavigableStep?.sentenceNumber == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTranslation.toggle()
                } label: {
                    Label("Traduction",
                          systemImage: showTranslation ? "eye" : "eye.slash")
                }
            }
        }
        .sheet(item: $pronunciationStep) { step in
            PronunciationView(step: step)
        }
        .onAppear {
            showTranslation = settings.revealTranslation
            // Sans ça, l'écran s'éteint toutes les 30 secondes alors qu'on suit
            // le texte, ce qui rend l'écran de lecture inutilisable.
            UIApplication.shared.isIdleTimerDisabled = true
            startIfNeeded()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            recordSession()
            player.pause()
        }
        .onChange(of: player.index) {
            recordReviewIfNeeded()
        }
    }

    // MARK: - Lignes de la séance

    /// Une ligne de l'écran, adossée à une étape navigable.
    private struct TranscriptRow: Identifiable {
        let stepIndex: Int
        let step: SessionStep
        /// Vrai quand cette ligne inaugure une leçon différente de la précédente.
        let startsNewLesson: Bool

        var id: Int { stepIndex }
    }

    private var rows: [TranscriptRow] {
        guard isCurrentSession else { return [] }
        var result: [TranscriptRow] = []
        var previousLesson: Int?
        for (index, step) in player.steps.enumerated() {
            // L'annonce ne fait que dire le numéro de la leçon : rien à lire.
            guard step.isNavigable, step.kind != .announcement else { continue }
            result.append(TranscriptRow(stepIndex: index,
                                        step: step,
                                        startsNewLesson: step.lessonNumber != previousLesson))
            previousLesson = step.lessonNumber
        }
        return result
    }

    /// Les phrases seules, pour situer où on en est.
    private var sentenceRows: [TranscriptRow] {
        rows.filter { $0.step.sentenceNumber != nil && $0.step.kind != .exerciseIntro }
    }

    /// Une séance à cheval sur plusieurs leçons doit dire laquelle on entend.
    private var spansSeveralLessons: Bool {
        guard isCurrentSession else { return false }
        return Set(player.steps.map(\.lessonNumber)).count > 1
    }

    // MARK: - Texte

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        if spansSeveralLessons, row.startsNewLesson {
                            Text("Leçon \(row.step.lessonNumber)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                        }
                        rowView(row)
                            .id(row.stepIndex)
                            .onTapGesture { player.seek(to: row.stepIndex) }
                    }

                    if rows.isEmpty {
                        Text(emptyMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if missingTextNotice {
                        Text("Texte non encore saisi pour cette leçon — l'audio fonctionne normalement.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .onChange(of: player.index) {
                guard let target = player.currentNavigableIndex else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow) -> some View {
        let isCurrent = player.currentNavigableIndex == row.stepIndex

        switch row.step.kind {
        case .title:
            Text(LessonTextStore.text(for: row.step.lessonNumber)?.titleES
                 ?? "Leçon \(row.step.lessonNumber)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .padding(.bottom, 4)

        case .exerciseIntro:
            Text("Exercice")
                .font(.headline)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .padding(.top, 6)

        default:
            SentenceRow(step: row.step,
                        isCurrent: isCurrent,
                        showTranslation: showTranslation,
                        isMarked: row.step.markKey.map(markedKeys.contains) ?? false)
        }
    }

    private var emptyMessage: String {
        request.isReview
            ? "Aucune phrase à revoir aujourd'hui."
            : "Cette séance ne contient aucune étape."
    }

    /// Seulement pour une leçon : en révision, les phrases viennent de partout et
    /// une note par leçon manquante serait du bruit.
    private var missingTextNotice: Bool {
        guard case .lesson(let number, _) = request else { return false }
        return !LessonTextStore.hasText(for: number)
    }

    // MARK: - Commandes

    private var controls: some View {
        VStack(spacing: 16) {
            if let step = player.currentStep, step.isPause {
                Label("À toi de répéter", systemImage: "mic")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            } else {
                Text(positionLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                controlButton("backward.end", size: 26) { player.previousOrReplay() }
                controlButton("arrow.counterclockwise", size: 26) { player.replayCurrent() }
                controlButton(player.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 64) {
                    player.togglePlayPause()
                }
                controlButton("flag", size: 26, filled: isCurrentMarked) { toggleMarkCurrent() }
                controlButton("forward.end", size: 26) { player.nextSentence() }
            }

            HStack {
                Image(systemName: "tortoise")
                Slider(value: Binding(
                    get: { Double(player.rate) },
                    set: { player.rate = Float($0); settings.rate = $0 }
                ), in: 0.6...1.4, step: 0.05)
                Image(systemName: "hare")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private func controlButton(_ symbol: String, size: CGFloat,
                               filled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: filled ? "\(symbol).fill" : symbol)
                .font(.system(size: size))
                .frame(width: max(44, size), height: max(44, size))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - État

    private var positionLabel: String {
        guard isCurrentSession, let current = player.currentNavigableIndex else {
            return request.subtitle
        }
        let sentences = sentenceRows
        guard let rank = sentences.firstIndex(where: { $0.stepIndex == current }) else {
            return request.subtitle
        }
        let step = sentences[rank].step
        let position = "\(rank + 1) sur \(sentences.count)"
        if request.isReview {
            return "Leçon \(step.lessonNumber), phrase \(step.sentenceNumber ?? 0) · \(position)"
        }
        return step.isExercise ? "Exercice \(position)" : "Phrase \(position)"
    }

    private var currentMarkKey: String? {
        guard isCurrentSession else { return nil }
        return player.currentNavigableStep?.markKey
    }

    private var isCurrentMarked: Bool {
        currentMarkKey.map(markedKeys.contains) ?? false
    }

    // MARK: - Actions

    private func startIfNeeded() {
        guard !isCurrentSession else { return }
        let steps = SessionBuilder.build(request,
                                         marks: ReviewSchedule.due(in: marks),
                                         settings: settings.session)
        player.start(request, steps: steps, from: resumeIndex)
        recordReviewIfNeeded()
    }

    /// La révision ne se reprend pas : la file est reconstruite à chaque fois, à
    /// partir de ce qui est dû au moment où on la lance.
    private var resumeIndex: Int {
        guard case .lesson(let number, let mode) = request else { return 0 }
        return progress.first {
            $0.lessonNumber == number && $0.mode == mode.rawValue
        }?.stepIndex ?? 0
    }

    /// En révision, le drapeau **retire** la phrase de la file et passe à la
    /// suivante : c'est le geste « celle-là est acquise », le seul de la séance.
    /// Ailleurs, il marque ou démarque comme avant.
    private func toggleMarkCurrent() {
        guard let step = player.currentNavigableStep,
              let n = step.sentenceNumber,
              let key = step.markKey
        else { return }

        if let existing = marks.first(where: { $0.key == key }) {
            context.delete(existing)
            if request.isReview { player.nextSentence() }
        } else {
            context.insert(DifficultSentence(lessonNumber: step.lessonNumber,
                                             sentenceNumber: n,
                                             isExercise: step.isExercise))
        }
    }

    /// Une phrase compte comme revue dès qu'elle est jouée : c'est de l'avoir
    /// réentendue et redite qui la révise, pas une note qu'on lui donnerait.
    private func recordReviewIfNeeded() {
        guard request.isReview, isCurrentSession,
              let step = player.currentNavigableStep,
              let key = step.markKey,
              !reviewed.contains(step.id)
        else { return }

        reviewed.insert(step.id)
        marks.first { $0.key == key }?.recordReview()
    }

    /// Sauvegarde la reprise et le temps écouté en quittant l'écran.
    private func recordSession() {
        if case .lesson(let number, let mode) = request {
            let entry = progress.first { $0.lessonNumber == number && $0.mode == mode.rawValue }
                ?? {
                    let new = LessonProgress(lessonNumber: number, mode: mode.rawValue)
                    context.insert(new)
                    return new
                }()
            entry.stepIndex = player.isFinished ? 0 : player.index
            entry.updatedAt = .now
            if player.isFinished { entry.completedAt = .now }
        }

        let seconds = player.playedSeconds
        guard seconds > 0 else { return }
        let today = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<StudyDay>()
        let existing = (try? context.fetch(descriptor))?.first {
            Calendar.current.isDate($0.day, inSameDayAs: today)
        }
        if let existing {
            existing.seconds += seconds
        } else {
            context.insert(StudyDay(day: today, seconds: seconds))
        }
    }
}

private struct SentenceRow: View {
    let step: SessionStep
    let isCurrent: Bool
    let showTranslation: Bool
    let isMarked: Bool

    private var text: SentenceText? { step.sentenceText }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(step.sentenceNumber.map(String.init) ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(text?.es ?? fallback)
                    .font(.body)
                    .foregroundStyle(text == nil ? .secondary : .primary)

                if let pron = text?.pron, isCurrent {
                    Text(pron)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if showTranslation, let fr = text?.fr {
                    Text(fr)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let note = text?.note, isCurrent {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if isMarked {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : .clear)
        }
    }

    private var fallback: String {
        let n = step.sentenceNumber ?? 0
        return step.isExercise ? "Exercice \(n)" : "Phrase \(n)"
    }
}
