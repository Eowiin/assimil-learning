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
    /// Pour une étape de la séance du jour : la phrase où reprendre, et qui prévenir
    /// quand la phrase change. La séance se souvient elle-même de sa reprise.
    var resumeSentence: Int? = nil
    var onSentenceChange: ((Int?) -> Void)? = nil
    /// Le passage à l'étape suivante. Toujours un geste : la fin de l'audio le met
    /// en avant, elle ne le déclenche pas.
    var stageAction: StageAction? = nil

    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query private var marks: [DifficultSentence]
    @Query private var progress: [LessonProgress]

    @State private var showTranslation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// La phrase en cours se place dans le tiers haut : on lit ce qui vient sans
    /// perdre ce qui vient d'être dit, comme les paroles d'un lecteur de musique.
    private static let currentLineAnchor = UnitPoint(x: 0.5, y: 0.3)
    /// La phrase sur laquelle on veut s'essayer. Ouvre l'écran de prononciation.
    @StateObject private var trial = VoiceTrial()
    @State private var showTrialDetails = false
    /// Étapes déjà comptées comme revues dans cette séance : rejouer une phrase
    /// ne doit pas repousser son échéance une seconde fois.
    @State private var reviewed: Set<UUID> = []

    private var markedKeys: Set<String> { Set(marks.map(\.key)) }
    private var isCurrentSession: Bool { player.request == request }

    var body: some View {
        transcript
            .safeAreaBar(edge: .bottom) { controls }
            .background(StudyStyle.paper)
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        // Pendant une séance, la barre d'onglets ne sert à rien et prend la
        // hauteur dont le texte a besoin.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTranslation.toggle()
                } label: {
                    Label("Traduction", systemImage: "translate")
                }
                .tint(showTranslation ? StudyStyle.accent : .primary)
                .accessibilityValue(showTranslation ? "Visible" : "Masquée")
            }
            ToolbarItem(placement: .topBarTrailing) { speedMenu }
        }
        .sheet(isPresented: $showTrialDetails) {
            PronunciationView(trial: trial)
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
            if trial.isOpen { trial.close() }
            recordSession()
            AudioLog.info("\(#fileID) disparaît")
            player.pause()
        }
        .onChange(of: scenePhase) {
            // La séance continue en arrière-plan : la reprise et le temps écouté
            // sont mis à l'abri au cas où l'app serait fermée depuis là.
            if scenePhase == .background { recordSession() }
        }
        .onChange(of: player.index) {
            recordReviewIfNeeded()
            if isCurrentSession {
                onSentenceChange?(player.currentNavigableStep?.sentenceNumber)
            }
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(rows) { row in
                        if spansSeveralLessons, row.startsNewLesson {
                            Text("Leçon \(row.step.lessonNumber)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                        }
                        rowView(row)
                            .id(row.stepIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: row.stepIndex) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { player.seek(to: row.stepIndex) }
                            .accessibilityHint("Écouter à partir de cette phrase")
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
                .padding(.horizontal, 24)
                .padding(.top, 12)
                // Assez de place sous la dernière phrase pour qu'elle monte à son tour
                // dans le tiers haut.
                .padding(.bottom, 240)
            }
            .onChange(of: player.index) {
                guard let target = player.currentNavigableIndex else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(target, anchor: Self.currentLineAnchor)
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
                .font(.title.weight(.bold))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.bottom, 4)

        case .exerciseIntro:
            Text("Exercice")
                .font(.headline)
                .foregroundStyle(isCurrent ? StudyStyle.accent : .secondary)
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
        switch request {
        case .lesson(let number, _), .daily(let number, _):
            return !LessonTextStore.hasText(for: number)
        case .review, .excerpt:
            return false
        }
    }

    // MARK: - Commandes

    /// Une rangée au pouce : le drapeau et le micro encadrent le transport, la
    /// progression au-dessus. La vitesse et la traduction, plus rares, sont en haut.
    private var controls: some View {
        VStack(spacing: 12) {
            if trial.isOpen {
                VoiceTrialPanel(trial: trial,
                                onDetails: { showTrialDetails = true },
                                onResume: resumeAfterTrial)
            } else if let stageAction {
                stageButton(stageAction)
            }

            VStack(spacing: 8) {
                HStack {
                    if let step = player.currentStep, step.isPause {
                        Label(repetitionLabel ?? "À toi de répéter", systemImage: "waveform")
                            .foregroundStyle(StudyStyle.accent)
                    } else {
                        // « Écoute » et non « séance » : arriver au bout de l'audio ne
                        // termine pas une leçon.
                        Text(player.isFinished ? (request.isReview ? "Révision terminée" : "Écoute terminée") : positionLabel)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                ProgressView(value: player.isFinished ? 1 : Double(player.index) / Double(max(1, player.steps.count)))
                    .accessibilityLabel("Progression de la séance")
            }

            HStack {
                Button { toggleMarkCurrent() } label: {
                    Image(systemName: isCurrentMarked ? "flag.fill" : "flag")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                }
                .disabled(currentMarkKey == nil)
                .foregroundStyle(isCurrentMarked ? StudyStyle.accent : .secondary)
                .accessibilityLabel(request.isReview ? "Phrase acquise, retirer des révisions" :
                                    (isCurrentMarked ? "Retirer des phrases à revoir" : "Marquer à revoir"))
                Spacer(minLength: 0)
                Button { player.previousOrReplay() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                // Relance la phrase en cours, ou la précédente si elle vient de
                // commencer : c'est aussi le geste « refais-la moi ».
                .accessibilityLabel("Phrase précédente")
                .accessibilityHint("Rejoue la phrase en cours depuis le début")
                Spacer(minLength: 0)
                Button { trial.isOpen ? resumeAfterTrial() : player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(StudyStyle.button)
                .accessibilityLabel(player.isPlaying ? "Mettre en pause" : "Lire")
                .accessibilityIdentifier("play-pause")
                Spacer(minLength: 0)
                Button { player.nextSentence() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .accessibilityLabel("Phrase suivante")
                Spacer(minLength: 0)
                Button { Task { await micTapped() } } label: {
                    Image(systemName: trial.isRecording ? "stop.circle.fill" : (trial.isOpen ? "mic.fill" : "mic"))
                        .font(trial.isRecording ? .title : .title3)
                        .frame(width: 48, height: 48)
                }
                .disabled(player.currentNavigableStep?.sentenceNumber == nil || trial.phase == .analysing)
                .foregroundStyle(trial.isRecording ? AnyShapeStyle(.red)
                                 : trial.isOpen ? AnyShapeStyle(StudyStyle.accent) : AnyShapeStyle(.secondary))
                .accessibilityLabel(trial.isRecording ? "Arrêter l’enregistrement" : "Ma voix")
                .accessibilityHint(trial.isRecording ? "" : "Arrête la séance et t'enregistre sur la phrase en cours")
                .accessibilityIdentifier("voice-mic")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyStyle.ink)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// La vitesse, réglage rare : un menu système plutôt qu'un outil permanent.
    private var speedMenu: some View {
        Menu {
            Picker("Vitesse de lecture", selection: Binding(
                get: { Self.speeds.min { abs($0 - Double(player.rate)) < abs($1 - Double(player.rate)) } ?? 1 },
                set: { player.rate = Float($0); settings.rate = $0 }
            )) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text("\(speed, format: .number.precision(.fractionLength(0...1)))×").tag(speed)
                }
            }
        } label: {
            Text("\(player.rate, format: .number.precision(.fractionLength(0...2)))×")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityLabel("Vitesse de lecture")
    }

    private static let speeds: [Double] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4]

    @ViewBuilder
    private func stageButton(_ action: StageAction) -> some View {
        if isCurrentSession && player.isFinished {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.symbol)
            }
            .buttonStyle(StudyPrimaryButtonStyle())
            .accessibilityIdentifier("stage-action")
        } else {
            Button(action: action.perform) {
                Label(action.title, systemImage: action.symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
            }
            // En verre clair tant que la piste joue : l'étape suivante est à portée,
            // sans prendre le pas sur le transport. Elle passe en avant à la fin.
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("stage-action")
        }
    }

    // MARK: - Ma voix

    /// Le micro arrête la séance et enregistre d'un même geste ; un second appui
    /// termine la prise. Sur une autre phrase que celle de l'essai ouvert, l'essai
    /// repart sur elle.
    private func micTapped() async {
        if !trial.isRecording {
            guard let step = player.currentNavigableStep, step.sentenceNumber != nil else { return }
            if trial.step?.id != step.id || !trial.isOpen {
                player.releaseAudio()
                trial.open(step)
            }
        }
        await trial.toggleRecording()
    }

    /// Referme l'essai, rend la sortie audio à la séance et la relance où elle était.
    private func resumeAfterTrial() {
        trial.close()
        player.play()
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
        if let repetitionLabel {
            return "Phrase \(position) · \(repetitionLabel.lowercased())"
        }
        return step.isExercise ? "Exercice \(position)" : "Phrase \(position)"
    }

    /// « Répétition 2 sur 3 », à l'étape Répétition de la séance du jour.
    private var repetitionLabel: String? {
        guard isCurrentSession,
              case .daily(_, .repetition(let times)) = request, times > 1,
              let step = player.currentStep, step.sentenceNumber != nil
        else { return nil }
        return "Répétition \(step.repetition) sur \(times)"
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
        player.start(request, steps: steps, from: resumeIndex(in: steps))
        recordReviewIfNeeded()
    }

    /// La révision ne se reprend pas : la file est reconstruite à chaque fois, à
    /// partir de ce qui est dû au moment où on la lance. L'étape du jour reprend à
    /// sa phrase, que le nombre de répétitions ait changé ou non.
    private func resumeIndex(in steps: [SessionStep]) -> Int {
        switch request {
        case .lesson(let number, let mode):
            return progress.first {
                $0.lessonNumber == number && $0.mode == mode.rawValue
            }?.stepIndex ?? 0
        case .daily:
            return resumeSentence.flatMap { SessionBuilder.index(ofSentence: $0, in: steps) } ?? 0
        case .review, .excerpt:
            return 0
        }
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
        save()
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
        save()
    }

    /// Sauvegarde la reprise et le temps écouté en quittant l'écran. Arriver au
    /// bout ne marque rien comme terminé : c'est la séance du jour qui valide.
    private func recordSession() {
        if case .lesson(let number, let mode) = request, isCurrentSession {
            // Une ligne par leçon (voir LessonProgress) : on reprend celle qui existe,
            // quel que soit son mode, au lieu d'en insérer une seconde qui la
            // remplacerait en silence.
            let entry = progress.first { $0.lessonNumber == number }
                ?? {
                    let new = LessonProgress(lessonNumber: number)
                    context.insert(new)
                    return new
                }()
            entry.mode = mode.rawValue
            entry.stepIndex = player.isFinished ? 0 : player.index
            entry.updatedAt = .now
        }

        StudyTime.record(player.takeUnrecordedSeconds(), in: context)
        save()
    }

    /// Chaque geste est enregistré aussitôt : attendre l'autosave ou le passage en
    /// arrière-plan perdait un drapeau à la moindre fermeture brutale.
    private func save() {
        try? context.save()
    }
}

/// L'essai en cours, au-dessus du transport : ce qui a été entendu, la mélodie en
/// un mot, la réécoute côte à côte et « Reprendre ». Le détail (courbe, tempo, ce
/// que la machine a compris) est à un appui.
private struct VoiceTrialPanel: View {
    @ObservedObject var trial: VoiceTrial
    let onDetails: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button { trial.toggleMine() } label: {
                    Label("Moi", systemImage: trial.recorder.playing == .mine ? "stop.fill" : "play.fill")
                }
                .disabled(trial.myTake == nil || trial.isRecording || trial.phase == .analysing)
                .accessibilityLabel(trial.recorder.playing == .mine ? "Arrêter : moi" : "Écouter : moi")
                Button { trial.toggleNative() } label: {
                    Label("Natif", systemImage: trial.recorder.playing == .native ? "stop.fill" : "play.fill")
                }
                .disabled(trial.isRecording)
                .accessibilityLabel(trial.recorder.playing == .native ? "Arrêter : le natif" : "Écouter : le natif")
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                }
                .disabled(trial.isRecording)
                .accessibilityLabel("Détails : courbe d'intonation et tempo")
                .accessibilityIdentifier("voice-details")
                Spacer(minLength: 0)
                Button(action: onResume) {
                    Label("Reprendre", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(StudyStyle.button)
                .disabled(trial.isRecording)
                .accessibilityIdentifier("voice-resume")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .lineLimit(1)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch trial.phase {
        case .ready:
            Text("Touche le micro et dis la phrase.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .recording:
            Label("J'écoute… touche ■ quand tu as fini.", systemImage: "waveform")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
        case .analysing:
            HStack(spacing: 8) {
                ProgressView()
                Text(trial.speech.status == .installingModel ? "Installation du modèle espagnol…" : "Reconnaissance…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                if !trial.verdicts.isEmpty {
                    FlowText(verdicts: trial.verdicts)
                }
                Text([trial.understoodLabel, trial.intonation?.verdict].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Un bouton de passage à l'étape suivante, fourni par la séance du jour.
struct StageAction {
    let title: String
    let symbol: String
    let perform: () -> Void
}

/// Une phrase, à la manière des paroles d'un lecteur de musique : la phrase en
/// cours en grand, avec sa prononciation et sa note ; les autres en retrait. Elle
/// se lit d'un coup d'œil, téléphone posé ou tenu à distance.
private struct SentenceRow: View {
    let step: SessionStep
    let isCurrent: Bool
    let showTranslation: Bool
    let isMarked: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: SentenceText? { step.sentenceText }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(step.sentenceNumber.map(String.init) ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 8) {
                Text(text?.es ?? fallback)
                    .font(isCurrent ? .title2.weight(.semibold) : .title3)
                    .foregroundStyle(isCurrent && text != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

                if isCurrent, let pron = text?.pron {
                    Text(pron)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if showTranslation, let fr = text?.fr {
                    Text(fr)
                        .font(isCurrent ? .body : .callout)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                if isCurrent, let note = text?.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if isMarked {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("À revoir")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCurrent)
    }

    private var fallback: String {
        let n = step.sentenceNumber ?? 0
        return step.isExercise ? "Exercice \(n)" : "Phrase \(n)"
    }
}
