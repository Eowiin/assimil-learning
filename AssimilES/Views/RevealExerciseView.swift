import SwiftUI

/// Chercher la réponse, la dire, puis la comparer.
///
/// Sert au premier exercice (l'espagnol en énoncé, le français en corrigé) et à la
/// deuxième vague (le français en énoncé, l'espagnol à restituer). Deux façons de
/// répondre, au choix :
///
/// - **au micro** : la reconnaissance, locale, rend ce qui a été dit. Identique à la
///   réponse attendue, la phrase est réussie sans geste. Sinon l'écran montre ce qui a
///   été entendu et les mots qui manquent — et c'est l'apprenant qui juge en
///   traduction, où une autre formulation peut être juste ;
/// - **de tête** : on affiche la réponse et on s'évalue, comme dans le livre.
struct RevealExerciseView: View {
    let stage: DailyStage
    let heading: String
    let instruction: String
    let lesson: Lesson
    let items: [RevealItem]
    let content: ActivityContent
    let revealTitle: String
    let promptFallback: String
    /// L'audio est l'énoncé (exercice 1) ou la réponse (deuxième vague).
    let clipIsPrompt: Bool
    /// Écoute la langue de la réponse : le français en traduction, l'espagnol en vague.
    @ObservedObject var listener: AnswerListener
    @Binding var progress: DailyProgress
    /// Une leçon à réécouter librement quand le texte manque.
    var listenLesson: Int?

    @EnvironmentObject private var player: SessionPlayer

    /// En deuxième vague, la réponse est une phrase espagnole précise : « pas
    /// identique » y veut dire « pas encore ». En traduction, non.
    private var verdictIsAutomatic: Bool { stage == .secondWave }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading).font(.title3.weight(.bold))
                    Text(instruction).font(.subheadline).foregroundStyle(.secondary)
                }

                if let notice = content.notice {
                    BookNotice(text: notice)
                }

                if !items.isEmpty, content != .notApplicable {
                    ForEach(items) { item in
                        card(item)
                    }
                }

                if content.needsBook {
                    BookConfirmation(stage: stage,
                                     label: stage == .secondWave
                                        ? "J'ai fait la restitution dans le livre"
                                        : "J'ai fait cet exercice dans le livre",
                                     progress: $progress)
                }

                if let listenLesson, content.needsBook {
                    NavigationLink {
                        PlayerView(request: .lesson(number: listenLesson, mode: .shadowing))
                    } label: {
                        Label("Écouter et répéter la leçon \(listenLesson)", systemImage: "headphones")
                    }
                    .font(.subheadline)
                }
            }
            .padding(20)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onDisappear { listener.cancel() }
    }

    // MARK: - Une phrase

    private func card(_ item: RevealItem) -> some View {
        let state = progress.reveal(stage, item.n)
        let key = "\(stage.rawValue)-\(lesson.number)-\(item.n)"
        let spoken = state.heard.flatMap { heard in
            item.answer.map { SpokenCheck.compare(heard: heard, expected: $0) }
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.n)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text(item.prompt ?? promptFallback)
                    .font(.title3)
                    .foregroundStyle(item.prompt == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                if clipIsPrompt, item.clip != nil {
                    playButton(item, label: "Écouter l'énoncé")
                }
                if let outcome = state.outcome {
                    Image(systemName: outcome == .knew ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                        .foregroundStyle(outcome == .knew ? StudyStyle.accent : .orange)
                        .accessibilityLabel(outcome == .knew ? "Réussie" : "À retravailler")
                }
            }

            Group {
                if state.revealed {
                    revealed(item, state: state, spoken: spoken, key: key)
                } else {
                    HStack(spacing: 10) {
                        if item.answer != nil {
                            micButton(item, key: key, title: "Répondre")
                        }
                        Button {
                            progress.setReveal(stage, item.n, RevealState(revealed: true))
                            if !clipIsPrompt { play(item) }
                        } label: {
                            Text(revealTitle).frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.bordered)
                        .disabled(listener.isBusy)
                        .accessibilityIdentifier("reveal-\(item.n)")
                    }
                }
                listening(key)
            }
            .padding(.leading, 28)
        }
        .padding(16)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func revealed(_ item: RevealItem, state: RevealState, spoken: SpokenResult?, key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.answer ?? "Corrigé pas encore importé : vérifie dans le livre.")
                    .font(.body.weight(item.answer == nil ? .regular : .medium))
                    .foregroundStyle(item.answer == nil ? .secondary : StudyStyle.accent)
                Spacer(minLength: 0)
                if !clipIsPrompt, item.clip != nil {
                    playButton(item, label: "Écouter la réponse")
                }
            }

            if let spoken {
                heardSummary(spoken, expected: item.answer ?? "")
            }

            if let answer = item.answer {
                if spoken?.isIdentical == true {
                    EmptyView()
                } else if spoken != nil, verdictIsAutomatic, SpokenCheck.isJudgeable(answer) {
                    // Deuxième vague : on redit, ou on passe.
                    HStack(spacing: 10) {
                        micButton(item, key: key, title: "Réessayer")
                        assessButton("Pas encore", outcome: .notYet, item: item, state: state)
                    }
                } else if spoken != nil {
                    // Pas mot pour mot : l'app ne sait pas si le sens y est.
                    HStack(spacing: 10) {
                        assessButton(verdictIsAutomatic ? "Je l'avais" : "Même sens",
                                     outcome: .knew, item: item, state: state)
                        assessButton("Pas encore", outcome: .notYet, item: item, state: state)
                    }
                    micButton(item, key: key, title: "Réessayer")
                } else {
                    HStack(spacing: 10) {
                        assessButton("Je l'avais", outcome: .knew, item: item, state: state)
                        assessButton("Pas encore", outcome: .notYet, item: item, state: state)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func heardSummary(_ spoken: SpokenResult, expected: String) -> some View {
        if spoken.isIdentical {
            Label(verdictIsAutomatic ? "Identique à l'espagnol attendu" : "Identique au corrigé",
                  systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyStyle.accent)
                .accessibilityIdentifier("spoken-identical")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entendu").font(.caption).foregroundStyle(.secondary)
                    Text("« \(spoken.heard) »").font(.callout).italic()
                }
                FlowText(verdicts: spoken.words)
                Text(differenceHint(expected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("spoken-different")
        }
    }

    private func differenceHint(_ expected: String) -> String {
        if !SpokenCheck.isJudgeable(expected) {
            return "Les chiffres s'écrivent autrement une fois reconnus : à toi de juger."
        }
        return verdictIsAutomatic
            ? "Les mots en orange ne sont pas passés. Réécoute, puis redis la phrase."
            : "Pas mot pour mot. Une autre traduction peut être juste : à toi de juger si le sens y est."
    }

    // MARK: - Micro

    private func micButton(_ item: RevealItem, key: String, title: String) -> some View {
        let recording = listener.phase == .recording(key: key)
        return Button {
            Task {
                if recording {
                    await answer(item)
                } else {
                    await listener.start(key, releasing: player)
                }
            }
        } label: {
            Label(recording ? "Terminer" : title, systemImage: recording ? "stop.fill" : "mic.fill")
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(recording ? .red : StudyStyle.button)
        .disabled(listener.isBusy && !recording)
        .accessibilityIdentifier("answer-mic-\(item.n)")
    }

    @ViewBuilder
    private func listening(_ key: String) -> some View {
        switch listener.phase {
        case .recording(let current) where current == key:
            Label("J'écoute… dis ta réponse, puis touche Terminer.", systemImage: "waveform")
                .font(.caption).foregroundStyle(.red)
        case .recognizing(let current) where current == key:
            HStack(spacing: 8) { ProgressView(); Text("Reconnaissance…") }
                .font(.caption).foregroundStyle(.secondary)
        case .installingModel(let current) where current == key:
            HStack(spacing: 8) { ProgressView(); Text("Installation du modèle de reconnaissance, une seule fois…") }
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let current, let message) where current == key:
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private func answer(_ item: RevealItem) async {
        guard let heard = await listener.finish(), let expected = item.answer else { return }
        let result = SpokenCheck.compare(heard: heard, expected: expected)
        var state = progress.reveal(stage, item.n)
        state.revealed = true
        state.heard = heard
        state.identical = result.isIdentical
        if result.isIdentical { state.outcome = .knew }
        progress.setReveal(stage, item.n, state)
        // En deuxième vague, entendre le natif juste après sa propre phrase est la
        // comparaison qui compte.
        if !clipIsPrompt { play(item) }
    }

    // MARK: - Briques

    private func assessButton(_ title: String, outcome: RevealOutcome,
                              item: RevealItem, state: RevealState) -> some View {
        let chosen = state.outcome == outcome
        return Button {
            var updated = state
            updated.revealed = true
            updated.outcome = outcome
            progress.setReveal(stage, item.n, updated)
        } label: {
            Text(title)
                .font(.subheadline.weight(chosen ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .tint(chosen ? StudyStyle.accent : .secondary)
        .disabled(listener.isBusy)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("assess-\(outcome.rawValue)-\(item.n)")
    }

    private func playButton(_ item: RevealItem, label: String) -> some View {
        Button { play(item) } label: {
            Image(systemName: "speaker.wave.2").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyStyle.accent)
        .disabled(listener.isBusy)
        .accessibilityLabel(label)
    }

    private func play(_ item: RevealItem) {
        guard let clip = item.clip else { return }
        player.start(.excerpt(lessonNumber: lesson.number),
                     steps: SessionBuilder.excerpt(clip, isExercise: stage == .translation, in: lesson))
    }
}
