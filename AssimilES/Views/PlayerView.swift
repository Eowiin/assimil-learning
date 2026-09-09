import SwiftUI
import SwiftData
import UIKit

/// L'écran de lecture : le texte de la leçon, la phrase en cours surlignée, et
/// des commandes assez grosses pour être atteintes au pouce en marchant.
struct PlayerView: View {
    let lesson: Lesson
    let mode: StudyMode

    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context

    @Query private var marks: [DifficultSentence]
    @Query private var progress: [LessonProgress]

    @State private var showTranslation = false

    private var text: LessonText? { LessonTextStore.text(for: lesson.number) }
    private var markedKeys: Set<String> { Set(marks.map(\.key)) }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            controls
        }
        .navigationTitle("Leçon \(lesson.number)")
        .navigationBarTitleDisplayMode(.inline)
        // Pendant une séance, la barre d'onglets ne sert à rien et prend la
        // hauteur dont le texte a besoin.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTranslation.toggle()
                } label: {
                    Label("Traduction",
                          systemImage: showTranslation ? "eye" : "eye.slash")
                }
                .disabled(text == nil)
            }
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
    }

    // MARK: - Texte

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let title = text?.titleES {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .padding(.bottom, 4)
                    }

                    ForEach(lesson.dialogue, id: \.file) { clip in
                        SentenceRow(clip: clip,
                                    text: clip.n.flatMap { text?.sentence($0) },
                                    isCurrent: isCurrent(clip),
                                    showTranslation: showTranslation,
                                    isMarked: isMarked(clip))
                        .id(clip.file)
                        .onTapGesture { jump(to: clip) }
                    }

                    if text == nil {
                        Text("Texte non encore saisi pour cette leçon — l'audio fonctionne normalement.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .onChange(of: player.index) {
                guard let file = currentClipFile else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(file, anchor: .center)
                }
            }
        }
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

    private var currentClipFile: String? {
        guard let n = player.currentSentenceNumber else { return nil }
        return lesson.dialogue.first { $0.n == n }?.file
    }

    private func isCurrent(_ clip: AudioClip) -> Bool {
        player.lesson?.number == lesson.number && player.currentSentenceNumber == clip.n
    }

    private var positionLabel: String {
        guard let n = player.currentSentenceNumber else { return mode.title }
        return "Phrase \(n) sur \(lesson.dialogue.count)"
    }

    private func isMarked(_ clip: AudioClip) -> Bool {
        guard let n = clip.n else { return false }
        return markedKeys.contains(DifficultSentence.makeKey(lesson.number, n, false))
    }

    private var isCurrentMarked: Bool {
        guard let n = player.currentSentenceNumber else { return false }
        return markedKeys.contains(DifficultSentence.makeKey(lesson.number, n, false))
    }

    // MARK: - Actions

    private func startIfNeeded() {
        guard player.lesson?.number != lesson.number || player.mode != mode else { return }
        let resume = progress.first { $0.lessonNumber == lesson.number && $0.mode == mode.rawValue }
        player.start(mode: mode, lesson: lesson,
                     settings: settings.session,
                     from: resume?.stepIndex ?? 0)
    }

    private func jump(to clip: AudioClip) {
        guard let target = player.steps.firstIndex(where: {
            $0.sentenceNumber == clip.n && $0.isNavigable
        }) else { return }
        player.seek(to: target)
        if !player.isPlaying { player.play() }
    }

    private func toggleMarkCurrent() {
        guard let n = player.currentSentenceNumber else { return }
        let key = DifficultSentence.makeKey(lesson.number, n, false)
        if let existing = marks.first(where: { $0.key == key }) {
            context.delete(existing)
        } else {
            context.insert(DifficultSentence(lessonNumber: lesson.number,
                                             sentenceNumber: n,
                                             isExercise: false))
        }
    }

    /// Sauvegarde la reprise et le temps écouté en quittant l'écran.
    private func recordSession() {
        let entry = progress.first { $0.lessonNumber == lesson.number && $0.mode == mode.rawValue }
            ?? {
                let new = LessonProgress(lessonNumber: lesson.number, mode: mode.rawValue)
                context.insert(new)
                return new
            }()
        entry.stepIndex = player.isFinished ? 0 : player.index
        entry.updatedAt = .now
        if player.isFinished { entry.completedAt = .now }

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
    let clip: AudioClip
    let text: SentenceText?
    let isCurrent: Bool
    let showTranslation: Bool
    let isMarked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(clip.n.map(String.init) ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(text?.es ?? "Phrase \(clip.n ?? 0)")
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
}
