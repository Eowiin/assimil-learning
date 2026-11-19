import SwiftUI
import SwiftData

/// La séance adaptative du jour (`docs/moteur-adaptatif.md`, étape 4) : l'objectif, le
/// thème, et les quatre blocs dans l'ordre. On ouvre le prochain bloc ; un bloc fait ou
/// passé ne revient pas. Le temps passé s'affiche, sans chronomètre qui coupe.
struct AdaptiveSessionView: View {
    let session: StudySession
    let pack: CurriculumPack

    @State private var openedBlock: StudyBlock?
    @Environment(\.modelContext) private var context
    @Environment(ServerStatus.self) private var server
    @Environment(AbsorptionPreparer.self) private var absorption

    private var objective: CurriculumPack.Objective? { session.objectiveID.flatMap(pack.objective) }
    private var theme: CurriculumPack.Theme? { pack.themes.first { $0.id == session.theme } }
    private var blocks: StudyBlockProgress { session.blocks }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                VStack(spacing: 12) {
                    ForEach(StudyBlock.allCases) { block in row(block) }
                }
                if blocks.isDone {
                    Label("Séance faite. À demain !", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(StudyStyle.accent)
                        .accessibilityIdentifier("adaptive-done")
                }
            }
            .padding(20)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(StudyStyle.paper)
        .navigationTitle("Séance du jour")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $openedBlock) { block in
            StudyBlockView(block: block, session: session, pack: pack)
        }
        // Le texte du bloc 2 et sa voix prennent une minute : ils se préparent pendant
        // le bloc 1. Un appel à l'IA même si le bloc 2 est passé ensuite.
        .onAppear(perform: prepareAbsorption)
        .onChange(of: server.isOnline) { prepareAbsorption() }
    }

    private func prepareAbsorption() {
        guard !blocks.isSettled(.absorption), absorption.phase(for: session) == .idle,
              let service = server.absorption else { return }
        absorption.prepare(session, pack: pack, service: service, in: context)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let objective {
                Text("Objectif · \(objective.level)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(objective.title)
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("adaptive-objective")
            } else {
                Text("Tous les objectifs sont acquis")
                    .font(.title2.weight(.bold))
            }
            if let theme {
                Label(theme.fr, systemImage: "text.book.closed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !session.newLemmas.isEmpty {
                Label("\(session.newLemmas.count) mots nouveaux", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ block: StudyBlock) -> some View {
        let isNext = blocks.next == block
        return Button {
            openedBlock = block
        } label: {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol(block, blocks: blocks))
                    .font(.title2)
                    .foregroundStyle(isNext || blocks.completed[block] != nil ? StudyStyle.accent : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.title).font(.headline)
                    Text(Self.detail(block, blocks: blocks))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isNext {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(isNext ? StudyStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // L'ordre est fixe : seul le prochain bloc s'ouvre. Un bloc réglé ne se rouvre
        // pas, mais il n'est pas grisé : il dit ce qui a été fait.
        .allowsHitTesting(isNext)
        .disabled(!isNext && !blocks.isSettled(block))
        .accessibilityIdentifier("block-\(block.rawValue)")
    }

    static func symbol(_ block: StudyBlock, blocks: StudyBlockProgress) -> String {
        if blocks.completed[block] != nil { return "checkmark.circle.fill" }
        if blocks.skipped[block] != nil { return "arrow.uturn.forward.circle" }
        return "\(StudyBlock.allCases.firstIndex(of: block).map { $0 + 1 } ?? 0).circle"
    }

    /// « Fait · 14 min », « Passé », ou ce que le bloc contient.
    static func detail(_ block: StudyBlock, blocks: StudyBlockProgress) -> String {
        let minutes = Int((blocks.seconds[block] ?? 0) / 60)
        if blocks.completed[block] != nil { return "Fait · \(minutes) min" }
        if blocks.skipped[block] != nil { return minutes > 0 ? "Passé · \(minutes) min" : "Passé" }
        return block.summary + (minutes > 0 ? " · \(minutes) min déjà" : "")
    }
}

extension StudyBlock {
    /// Ce que le bloc contient, en une ligne.
    var summary: String {
        switch self {
        case .surgery: "Révisions, micro-leçon, tes sons faibles"
        case .absorption: "Le texte du jour, à écouter et à lire"
        case .conversation: "Le jeu de rôle de l'objectif"
        case .automation: "Oral en rafale, puis un court écrit"
        }
    }
}

/// Un bloc de la séance : son contenu, le temps passé, « Bloc fait » et « Passer ».
///
/// Le temps du bloc court tant qu'il est ouvert, écrans qu'il ouvre compris (la révision,
/// la prononciation) : c'est lui qui s'affiche et qui vise 15 min. Ces écrans inscrivent
/// déjà leur temps d'étude ; le bloc n'inscrit que le sien propre, sans compter deux fois.
struct StudyBlockView: View {
    let block: StudyBlock
    let session: StudySession
    let pack: CurriculumPack

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Le bloc entier, écrans ouverts compris.
    @State private var clock = BlockClock()
    /// Le bloc seul, arrêté pendant qu'un autre écran est ouvert par-dessus.
    @State private var ownClock = BlockClock()
    /// Une partie ouverte par-dessus le bloc : on n'en est pas sorti.
    @State private var childOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(Self.elapsed(clock.seconds(at: context.date) + (session.blocks.seconds[block] ?? 0)),
                          systemImage: "clock")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("block-time")
                }
                Button("Bloc fait") { finish(skipped: false) }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .accessibilityIdentifier("block-complete")
                Button("Passer ce bloc") { finish(skipped: true) }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("block-skip")
            }
            .padding(20)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StudyStyle.paper)
        .navigationTitle(block.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            childOpen = false
            clock.resume()
            ownClock.resume()
        }
        .onDisappear {
            ownClock.pause()
            if !childOpen { saveTime() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                clock.resume()
                if !childOpen { ownClock.resume() }
            } else {
                clock.pause()
                ownClock.pause()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .surgery:
            SurgeryBlockContent(session: session, pack: pack) { childOpen = true }
        case .absorption:
            AbsorptionBlockContent(session: session, pack: pack)
        case .conversation:
            ConversationBlockContent(session: session, pack: pack) { childOpen = true }
        case .automation:
            AutomationBlockContent(session: session, pack: pack) { childOpen = true }
        }
    }

    /// « 4 min 12 s » ; l'heure n'est pas visée, mais elle s'affiche.
    static func elapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return "\(total / 60) min \(String(format: "%02d", total % 60)) s"
    }

    private func finish(skipped: Bool) {
        let seconds = clock.take()
        if skipped {
            StudySessionProgress.skip(block, seconds: seconds, in: session, at: .now)
        } else {
            StudySessionProgress.complete(block, seconds: seconds, in: session, at: .now)
        }
        StudyTime.record(ownClock.take(), as: .adaptive, in: context)
        try? context.save()
        dismiss()
    }

    /// Parti sans finir : le temps est gardé dans le bloc.
    private func saveTime() {
        let seconds = clock.take()
        let own = ownClock.take()
        guard seconds >= 1 else { return }
        StudySessionProgress.addTime(seconds, to: block, in: session)
        StudyTime.record(own, as: .adaptive, in: context)
        try? context.save()
    }
}

/// Le temps passé dans un bloc : il court tant que l'écran est au premier plan.
struct BlockClock {
    private var runningSince: Date?
    private var banked: Double = 0

    mutating func resume(at date: Date = .now) {
        if runningSince == nil { runningSince = date }
    }

    mutating func pause(at date: Date = .now) {
        guard let start = runningSince else { return }
        banked += max(0, date.timeIntervalSince(start))
        runningSince = nil
    }

    func seconds(at date: Date = .now) -> Double {
        banked + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    /// Le temps accumulé, remis à zéro (l'horloge continue si elle courait).
    mutating func take(at date: Date = .now) -> Double {
        let total = seconds(at: date)
        banked = 0
        if runningSince != nil { runningSince = date }
        return total
    }
}
