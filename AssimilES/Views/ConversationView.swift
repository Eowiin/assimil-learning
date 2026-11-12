import SwiftUI
import SwiftData

/// La conversation avec l'IA, en talkie-walkie : elle ouvre, on touche le micro
/// pour parler, on touche à nouveau pour envoyer, elle répond à voix haute.
/// « Terminer » garde la conversation sur l'iPhone et montre le récapitulatif. La
/// règle vit dans `ConversationSession` ; l'écran affiche et transmet.
struct ConversationView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var settings: AppSettings

    @State private var session: ConversationSession
    /// Les répliques de l'IA dont on a demandé le texte, quand il est masqué.
    @State private var revealed: Set<ConversationLine.ID> = []
    /// Secondes d'étude pas encore inscrites (`StudyTime`).
    @State private var unrecorded: Double = 0
    @State private var lastTick = DayClock.systemNow()
    /// Terminée : l'écran montre le récapitulatif.
    @State private var finished = false
    /// La conversation gardée, complétée par les corrections quand elles arrivent.
    @State private var record: ConversationRecord?

    /// Un silence de plus de deux minutes ne compte que pour deux : le téléphone
    /// posé ne fait pas du temps d'étude.
    private static let maxGap: Double = 120

    init(service: any ConversationService) {
        _session = State(initialValue: ConversationSession(service: service, sound: Self.sound()))
    }

    private static func sound() -> any ConversationSound {
        #if DEBUG
        if AppEnvironment.fakeServer { return SilentSound() }
        #endif
        return ConversationAudio()
    }

    var body: some View {
        Group {
            if finished {
                ConversationRecapView(review: session.review) { await review() }
            } else {
                VStack(spacing: 0) {
                    transcript
                    controls
                }
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyStyle.paper)
        .navigationTitle(finished ? "Récapitulatif" : "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if finished {
                    Button("Fermer") { dismiss() }
                        .accessibilityIdentifier("recap-close")
                } else {
                    Button("Terminer") { finish() }
                        .accessibilityIdentifier("conversation-end")
                }
            }
        }
        .task {
            player.pause()
            lastTick = DayClock.systemNow()
            await session.open()
        }
        .onDisappear {
            session.close()
            // Partie par le bouton retour : la conversation est gardée quand même,
            // sans récapitulatif.
            save()
            recordTime()
        }
        .onChange(of: session.phase) { tick() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { recordTime() }
            if scenePhase == .active { lastTick = DayClock.systemNow() }
        }
    }

    // MARK: - Les bulles

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.lines) { line in
                        bubble(line).id(line.id)
                    }
                    if session.phase == .opening || session.phase == .waiting {
                        thinking.id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .onChange(of: session.lines.count) {
                withAnimation { proxy.scrollTo(session.lines.last?.id, anchor: .bottom) }
            }
            .onChange(of: session.phase) {
                if session.phase == .waiting { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ line: ConversationLine) -> some View {
        switch line.speaker {
        case .learner:
            HStack {
                Spacer(minLength: 48)
                Text(line.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(StudyStyle.button, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("Toi : \(line.text)")
            }
        case .partner:
            HStack(alignment: .bottom, spacing: 8) {
                partnerText(line)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                if line.audio?.isEmpty == false {
                    Button {
                        session.replay(line)
                    } label: {
                        Image(systemName: session.playingLine == line.id ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.title2)
                            .foregroundStyle(StudyStyle.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.playingLine == line.id ? "Arrêter" : "Réécouter")
                }
                Spacer(minLength: 32)
            }
        }
    }

    /// Le texte masqué se montre d'un appui : on écoute d'abord, on lit si besoin.
    @ViewBuilder
    private func partnerText(_ line: ConversationLine) -> some View {
        if settings.conversationShowsText || revealed.contains(line.id) {
            Text(line.text)
                .accessibilityIdentifier("partner-line")
        } else {
            Button {
                revealed.insert(line.id)
            } label: {
                Label("Afficher le texte", systemImage: "eye")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(session.phase == .opening ? "L'IA prépare la conversation…" : "L'IA t'écoute et réfléchit…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Le micro

    private var controls: some View {
        VStack(spacing: 10) {
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
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(StudyStyle.paper)
    }

    private var micButton: some View {
        let recording = session.phase == .recording
        let busy = session.phase == .opening || session.phase == .waiting
        return Button {
            Task { await session.toggleMic() }
        } label: {
            Image(systemName: recording ? "arrow.up" : "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(recording ? Color.red : StudyStyle.button, in: Circle())
                .symbolEffect(.pulse, isActive: recording)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(busy || isFailed)
        .opacity(busy || isFailed ? 0.4 : 1)
        .sensoryFeedback(.start, trigger: recording)
        .accessibilityLabel(recording ? "Envoyer" : "Parler")
        .accessibilityIdentifier("conversation-mic")
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .ready:
            hint("Touche le micro pour répondre")
        case .recording:
            hint("Je t'écoute… touche pour envoyer")
        case .opening, .waiting:
            hint(" ")
        case .micDenied:
            hint("Le micro est refusé : autorise-le dans Réglages › Assimil")
        case .failed(let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Réessayer", systemImage: "arrow.clockwise") {
                    Task { await session.retry() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("conversation-retry")
            }
            .padding(.horizontal, 20)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: - Fin

    /// Sans phrase de l'apprenant, rien à garder ni à corriger : on revient à
    /// l'accueil.
    private func finish() {
        guard session.learnerSpoke else { return dismiss() }
        session.close()
        save()
        recordTime()
        withAnimation { finished = true }
        Task { await review() }
    }

    private func review() async {
        await session.requestReview()
        if case .done(let corrections) = session.review, let record {
            record.reviewedCorrections = corrections
            try? context.save()
        }
    }

    private func save() {
        guard record == nil, session.learnerSpoke else { return }
        let saved = ConversationRecord(startedAt: session.startedAt, endedAt: DayClock.systemNow(),
                                       messages: session.history)
        context.insert(saved)
        try? context.save()
        record = saved
    }

    // MARK: - Temps d'étude

    private func tick() {
        let now = DayClock.systemNow()
        unrecorded += min(max(0, now.timeIntervalSince(lastTick)), Self.maxGap)
        lastTick = now
    }

    private func recordTime() {
        tick()
        StudyTime.record(unrecorded, as: .conversation, in: context)
        unrecorded = 0
        try? context.save()
    }
}
