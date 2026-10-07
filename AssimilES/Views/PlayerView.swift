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
    @State private var showSpeed = false
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
            controls
        }
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
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityValue(showTranslation ? "Visible" : "Masquée")
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
                .padding(20)
            }
            .onChange(of: scenePhase) {
            // La séance continue en arrière-plan : la reprise et le temps écouté
            // sont mis à l'abri au cas où l'app serait fermée depuis là.
            if scenePhase == .background { recordSession() }
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
                .font(.title.weight(.bold))
                .foregroundStyle(isCurrent ? StudyStyle.accent : .primary)
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

    private var controls: some View {
        VStack(spacing: 16) {
            if let stageAction {
                stageButton(stageAction)
            }

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
            .font(.subheadline.weight(.medium))

            ProgressView(value: player.isFinished ? 1 : Double(player.index) / Double(max(1, player.steps.count)))
                .accessibilityLabel("Progression de la séance")

            HStack(spacing: 40) {
                Button { player.previousOrReplay() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24)).frame(width: 52, height: 52)
                }
                .accessibilityLabel("Phrase précédente")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .foregroundStyle(.white)
                        .background(StudyStyle.button, in: Circle())
                }
                .accessibilityLabel(player.isPlaying ? "Mettre en pause" : "Lire")
                .accessibilityIdentifier("play-pause")
                Button { player.nextSentence() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24)).frame(width: 52, height: 52)
                }
                .accessibilityLabel("Phrase suivante")
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyStyle.ink)
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                studyTool("arrow.counterclockwise", label: "Répéter") { player.replayCurrent() }
                studyTool(isCurrentMarked ? "flag.fill" : "flag",
                          label: request.isReview ? "Acquise" : "À revoir") { toggleMarkCurrent() }
                    .disabled(currentMarkKey == nil)
                    .foregroundStyle(isCurrentMarked ? StudyStyle.accent : .secondary)
                    .accessibilityLabel(request.isReview ? "Phrase acquise, retirer des révisions" :
                                        (isCurrentMarked ? "Retirer des phrases à revoir" : "Marquer à revoir"))
                studyTool("mic", label: "Ma voix") { pronunciationStep = player.currentNavigableStep }
                    .disabled(player.currentNavigableStep?.sentenceNumber == nil)
                Button { showSpeed = true } label: {
                    VStack(spacing: 6) {
                        Text("\(player.rate, format: .number.precision(.fractionLength(2)))×")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .frame(height: 22)
                        Text("Vitesse").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Vitesse de lecture")
                .popover(isPresented: $showSpeed) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("Vitesse de lecture").font(.headline)
                            Spacer()
                            Button("Terminé") { showSpeed = false }
                        }
                        HStack {
                            Text("0,6×").font(.caption)
                            Slider(value: Binding(
                                get: { Double(player.rate) },
                                set: { player.rate = Float($0); settings.rate = $0 }
                            ), in: 0.6...1.4, step: 0.05)
                            .accessibilityLabel("Vitesse de lecture")
                            Text("1,4×").font(.caption)
                        }
                        Text("\(player.rate, format: .number.precision(.fractionLength(2)))×")
                            .monospacedDigit().frame(maxWidth: .infinity)
                    }
                    .padding(24)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.height(210)])
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(StudyStyle.paper)
        .overlay(alignment: .top) { Divider() }
    }

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
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("stage-action")
        }
    }

    private func studyTool(_ symbol: String, label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 19)).frame(height: 22)
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
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

/// Un bouton de passage à l'étape suivante, fourni par la séance du jour.
struct StageAction {
    let title: String
    let symbol: String
    let perform: () -> Void
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

            VStack(alignment: .leading, spacing: 8) {
                Text(text?.es ?? fallback)
                    .font(.title3)
                    .lineSpacing(4)
                    .foregroundStyle(text == nil ? .secondary : .primary)

                if let pron = text?.pron, isCurrent {
                    Text(pron)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background {
            Rectangle()
                .fill(isCurrent ? StudyStyle.highlight : .clear)
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(StudyStyle.accent).frame(width: 3).padding(.vertical, 16)
            }
        }
    }

    private var fallback: String {
        let n = step.sentenceNumber ?? 0
        return step.isExercise ? "Exercice \(n)" : "Phrase \(n)"
    }
}
