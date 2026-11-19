import SwiftUI
import SwiftData

/// Une conversation réglée d'avance : celle du calibrage du placement, ou le jeu de
/// rôle de la séance du jour. Un profil fixé (niveau, objectif, lemmes connus), parfois
/// un nombre de réponses, et ce qu'il faut faire du récapitulatif.
struct ConversationSetup {
    let profile: ConversationProfile
    /// Le nombre de réponses au-delà duquel le micro se tait. Nil : sans limite.
    var turns: Int? = nil
    /// La ligne au-dessus des bulles. Nil : le résumé du profil, s'il en a un.
    var intro: String? = nil
    /// La durée visée (la rafale du bloc 4) : un décompte, puis une invitation à
    /// terminer. Rien ne coupe. Nil : pas de durée.
    var targetSeconds: Double? = nil
    /// Le titre de l'écran. Nil : « Conversation ».
    var title: String? = nil
    /// Le récapitulatif reçu, une fois par conversation (même après « Réessayer »).
    var onReview: ((ConversationReview) -> Void)? = nil
    /// La fin rend la main au lieu de fermer l'écran (« Continuer ») : le récapitulatif
    /// (nil s'il a échoué, ou sans phrase) et le nombre de réponses. Nil : « Fermer ».
    var onDone: ((ConversationReview?, Int) -> Void)? = nil
}

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
    /// Les fautes des conversations d'avant celle-ci, lues en terminant.
    @State private var earlier = ErrorPatterns(conversations: [])

    /// Un silence de plus de deux minutes ne compte que pour deux : le téléphone
    /// posé ne fait pas du temps d'étude.
    private static let maxGap: Double = 120

    /// Le calibrage du placement ou le jeu de rôle de la séance ; nil pour la
    /// conversation libre.
    private let setup: ConversationSetup?
    /// Le récapitulatif a déjà été remis à `setup.onReview`.
    @State private var reviewReported = false

    init(service: any ConversationService, setup: ConversationSetup? = nil) {
        self.setup = setup
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
                ConversationRecapView(review: session.review, objectiveUses: session.lastReview?.objectiveUses,
                                      earlier: earlier) { await review() }
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
        .navigationTitle(finished ? "Récapitulatif" : setup?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if finished, let onDone = setup?.onDone {
                    Button("Continuer") { onDone(session.lastReview, session.learnerTurns) }
                        .disabled(session.review == .loading)
                        .accessibilityIdentifier("calibration-continue")
                } else if finished {
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
            if let setup {
                session.profile = setup.profile
                session.turnLimit = setup.turns
            } else if session.profile == nil {
                session.profile = Self.profile(in: context)
            }
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
                    if let intro = setup?.intro {
                        Text(intro)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("conversation-intro")
                    } else if let summary = session.profile?.summary {
                        // Ce que le partenaire a reçu : on voit ce qu'il cherche à faire
                        // pratiquer, et qu'il a bien reçu quelque chose.
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("conversation-profile")
                    }
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
            if let target = setup?.targetSeconds {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdown(target, now: context.date)
                }
            } else {
                status
            }
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
        .disabled(busy || isFailed || session.reachedLimit)
        .opacity(busy || isFailed || session.reachedLimit ? 0.4 : 1)
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
        case .ready where session.reachedLimit:
            hint("C'est assez pour situer ton niveau : touche Terminer")
        case .ready:
            if let limit = session.turnLimit {
                hint("Touche le micro pour répondre (\(session.learnerTurns + 1) sur \(limit))")
            } else {
                hint("Touche le micro pour répondre")
            }
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

    /// Le temps qui reste, puis « touche Terminer » une fois la durée passée, quand
    /// c'est à l'apprenant.
    @ViewBuilder
    private func countdown(_ target: Double, now: Date) -> some View {
        let left = max(0, target - now.timeIntervalSince(session.startedAt))
        if left == 0, session.phase == .ready {
            hint("C'est \(Int(target / 60)) minutes : touche Terminer")
                .accessibilityIdentifier("conversation-time-up")
        } else {
            VStack(spacing: 4) {
                Text("\(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation-countdown")
                status
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Le profil envoyé au partenaire : la faute qui revient, les mots à reprendre.
    private static func profile(in context: ModelContext) -> ConversationProfile? {
        let records = (try? context.fetch(FetchDescriptor<ConversationRecord>())) ?? []
        let recognize = Card.Angle.recognize, recall = Card.Angle.recall
        let cards = (try? context.fetch(FetchDescriptor<Card>(
            predicate: #Predicate { $0.angle == recognize || $0.angle == recall }))) ?? []
        return ConversationProfile.make(patterns: ErrorPatterns(records: records), cards: cards)
    }

    // MARK: - Fin

    /// Sans phrase de l'apprenant, rien à garder ni à corriger : on revient à
    /// l'accueil.
    private func finish() {
        guard session.learnerSpoke else {
            // Le calibrage rend la main au test, qu'il ne faut pas fermer.
            if let onDone = setup?.onDone { return onDone(nil, 0) }
            return dismiss()
        }
        session.close()
        // Avant de garder celle-ci : elle ne compte pas parmi les précédentes.
        earlier = ErrorPatterns(records: (try? context.fetch(FetchDescriptor<ConversationRecord>())) ?? [])
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
        if !reviewReported, let reviewed = session.lastReview, let onReview = setup?.onReview {
            reviewReported = true
            onReview(reviewed)
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
