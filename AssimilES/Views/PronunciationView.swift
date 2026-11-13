import SwiftUI
import SwiftData

/// La séance de prononciation : une phrase, le natif, sa prise, puis le son fautif
/// marqué dans le mot et détaillé dessous (`docs/module-prononciation.md`). La
/// règle vit dans `PronunciationSession` ; l'écran affiche et transmet.
struct PronunciationView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: SessionPlayer

    @State private var session: PronunciationSession
    /// Secondes d'étude pas encore inscrites (`StudyTime`).
    @State private var unrecorded: Double = 0
    @State private var lastTick = DayClock.systemNow()

    /// Un silence de plus de deux minutes ne compte que pour deux : le téléphone
    /// posé ne fait pas du temps d'étude.
    private static let maxGap: Double = 120

    /// `context` : chaque prise jugée y est gardée (`PronunciationRecord`).
    init(sentences: [DrillSentence], service: any PronunciationService, manifest: Manifest,
         context: ModelContext) {
        _session = State(initialValue: PronunciationSession(
            sentences: sentences, service: service, sound: Self.sound(),
            nativeURL: { sentence in
                manifest.lesson(sentence.lesson).flatMap { manifest.url(for: sentence.clip, in: $0) }
            },
            onJudged: { sentence, attempt, result in
                context.insert(PronunciationRecord(judgedAt: DayClock.systemNow(), sentence: sentence,
                                                   attempt: attempt, result: result))
                try? context.save()
            }))
    }

    private static func sound() -> any PronunciationSound {
        #if DEBUG
        if AppEnvironment.fakeServer { return SilentPronunciationSound() }
        #endif
        return PronunciationAudio()
    }

    var body: some View {
        Group {
            if session.phase == .finished {
                summary
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            progress
                            sentenceCard
                            feedback
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                    controls
                }
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyStyle.paper)
        .navigationTitle("Prononciation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if session.phase == .finished {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                        .accessibilityIdentifier("pronunciation-close")
                }
            }
        }
        .task {
            player.pause()
            lastTick = DayClock.systemNow()
            session.open()
        }
        .onDisappear {
            session.close()
            recordTime()
        }
        .onChange(of: session.phase) { tick() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { recordTime() }
            if scenePhase == .active { lastTick = DayClock.systemNow() }
        }
    }

    // MARK: - La phrase

    private var progress: some View {
        Text("Phrase \(session.index + 1) sur \(session.sentences.count)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("pronunciation-progress")
    }

    private var sentenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            WordFlow(spacing: 6, lineSpacing: 8) {
                ForEach(session.words) { word in
                    wordButton(word)
                }
            }
            HStack(spacing: 10) {
                playButton("Natif", systemImage: "speaker.wave.2.fill", active: session.playing == .native) {
                    session.playNative()
                }
                .accessibilityIdentifier("pronunciation-native")
                if session.result != nil {
                    playButton("Ma prise", systemImage: "person.wave.2.fill", active: session.playing == .take) {
                        session.playTake()
                    }
                    .accessibilityIdentifier("pronunciation-take")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func wordButton(_ word: DisplayedWord) -> some View {
        let focused = session.focusWord?.id == word.id && (word.isFault || word.hasHint)
        return Button {
            session.select(word)
        } label: {
            wordText(word)
                .font(.title2)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(focused ? StudyStyle.yellow.opacity(0.35) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Pas `.disabled` : il griserait la phrase avant la première prise.
        .allowsHitTesting(word.judged != nil)
        .accessibilityLabel(word.isFault ? "\(word.text), à reprendre" : word.text)
        .accessibilityIdentifier(word.isFault ? "word-fault" : "word")
    }

    /// Le mot, avec les lettres du son fautif en rouge et soulignées. Un indice est
    /// seulement souligné en pointillé.
    private func wordText(_ word: DisplayedWord) -> Text {
        let phone = word.judged.flatMap { $0.phonemes.first(where: \.fault) ?? $0.phonemes.first(where: \.hint) }
        guard let phone, word.isFault || word.hasHint else { return Text(word.text) }
        let color: Color = word.isFault ? .red : .secondary
        let pattern: Text.LineStyle.Pattern = word.isFault ? .solid : .dot
        guard let range = SpanishSpelling.letters(of: phone, in: word) else {
            return Text(word.text).foregroundStyle(word.isFault ? color : .primary).underline(pattern: pattern, color: color)
        }
        return Text(word.text[..<range.lowerBound])
            + Text(word.text[range]).bold().foregroundStyle(color).underline(pattern: pattern, color: color)
            + Text(word.text[range.upperBound...])
    }

    // MARK: - Le retour

    @ViewBuilder
    private var feedback: some View {
        switch session.phase {
        case .judging:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("J'écoute tes sons…").foregroundStyle(.secondary)
            }
        case .judged:
            if let phone = session.focusPhone {
                faultCard(phone)
            } else {
                Label("Bien ! Tous les sons sont passés.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("pronunciation-good")
            }
        case .failed(let reason):
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private func faultCard(_ phone: JudgedPhone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let word = session.focusWord {
                Text(word.text.trimmingCharacters(in: .punctuationCharacters))
                    .font(.headline)
            }
            Text(SpanishSounds.correction(for: phone))
                .font(.body.weight(.medium))
                .accessibilityIdentifier("pronunciation-correction")
            if let tip = phone.tip {
                Label(tip, systemImage: "mouth")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if session.focusWord?.judged?.timeRange != nil {
                    playButton("Mon mot", systemImage: "waveform", active: session.playing == .word) {
                        session.playFocusWord()
                    }
                    .accessibilityIdentifier("pronunciation-word")
                }
                playButton("Natif", systemImage: "speaker.wave.2.fill", active: session.playing == .native) {
                    session.playNative()
                }
            }
            if session.words.filter(\.isFault).count > 1 {
                Text("Touche un autre mot en rouge pour voir sa faute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func playButton(_ title: String, systemImage: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(active ? "Stop" : title, systemImage: active ? "stop.fill" : systemImage)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(StudyStyle.accent)
    }

    // MARK: - Le micro

    private var controls: some View {
        VStack(spacing: 12) {
            status
            HStack(spacing: 24) {
                if session.phase == .recording {
                    Button("Annuler", systemImage: "xmark") { session.cancelRecording() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(StudyStyle.surface, in: Circle())
                        .accessibilityLabel("Annuler la prise")
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
                micButton
                nextButton
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(StudyStyle.paper)
    }

    private var micButton: some View {
        let recording = session.phase == .recording
        let busy = session.phase == .judging || isFailed
        return Button {
            Task { await session.toggleMic() }
        } label: {
            Image(systemName: recording ? "arrow.up" : session.result == nil ? "mic.fill" : "arrow.counterclockwise")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(recording ? Color.red : StudyStyle.button, in: Circle())
                .symbolEffect(.pulse, isActive: recording)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
        .sensoryFeedback(.start, trigger: recording)
        .accessibilityLabel(recording ? "Envoyer" : session.result == nil ? "Lire la phrase" : "Réessayer")
        .accessibilityIdentifier("pronunciation-mic")
    }

    /// « Suivante » une fois la phrase passée ; « Passer » quand le serveur échoue.
    @ViewBuilder
    private var nextButton: some View {
        if session.canAdvance || isFailed {
            Button {
                withAnimation { session.next() }
            } label: {
                Image(systemName: session.isLast ? "checkmark" : "chevron.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .background(StudyStyle.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFailed ? "Passer" : session.isLast ? "Terminer" : "Phrase suivante")
            .accessibilityIdentifier("pronunciation-next")
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .ready:
            hint("Écoute le natif, puis touche le micro et lis")
        case .recording:
            hint("Je t'écoute… touche pour envoyer")
        case .judged:
            if session.canAdvance {
                hint(session.result?.hasFault == true ? "Réessaie, ou passe à la suite" : "Phrase suivante →")
            } else {
                hint("Réessaie la phrase en visant ce son")
            }
        case .micDenied:
            hint("Le micro est refusé : autorise-le dans Réglages › Assimil")
        case .failed:
            Button("Renvoyer la prise", systemImage: "arrow.clockwise") {
                Task { await session.retry() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("pronunciation-retry")
        case .judging, .finished:
            hint(" ")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
    }

    // MARK: - Le bilan

    private var summary: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(StudyStyle.accent)
            if session.sentences.isEmpty {
                Text("Aucune phrase à travailler pour l'instant.")
                    .font(.headline)
            } else if session.summary.isEmpty {
                Text("Aucune faute sur la séance. ¡Muy bien!")
                    .font(.headline)
                    .accessibilityIdentifier("pronunciation-summary")
            } else {
                Text("Les sons à reprendre")
                    .font(.headline)
                    .accessibilityIdentifier("pronunciation-summary")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.summary, id: \.symbol) { item in
                        HStack {
                            Text(SpanishSounds.label(item.symbol).capitalizedFirst)
                            Spacer()
                            Text(item.count == 1 ? "1 fois" : "\(item.count) fois")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Temps d'étude

    private func tick() {
        let now = DayClock.systemNow()
        unrecorded += min(max(0, now.timeIntervalSince(lastTick)), Self.maxGap)
        lastTick = now
    }

    private func recordTime() {
        tick()
        StudyTime.record(unrecorded, as: .pronunciation, in: context)
        unrecorded = 0
        try? context.save()
    }
}

private extension String {
    /// « le r roulé » → « Le r roulé ».
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Les mots de la phrase, à la ligne quand la place manque.
struct WordFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : spacing + size.width
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap: CGFloat = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// L'entrée de la séance : les phrases sont tirées une fois, à l'ouverture, et pas
/// à chaque fois que l'accueil se redessine (elles lisent les textes des leçons).
struct PronunciationEntry: View {
    let service: any PronunciationService
    let lessons: Set<Int>

    @Environment(\.manifest) private var manifest
    @Environment(\.modelContext) private var context
    @State private var sentences: [DrillSentence]?

    var body: some View {
        if let sentences {
            PronunciationView(sentences: sentences, service: service, manifest: manifest, context: context)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudyStyle.paper)
                .task {
                    sentences = PronunciationDrill.pick(
                        from: PronunciationDrill.candidates(lessons: lessons, manifest: manifest))
                }
        }
    }
}
