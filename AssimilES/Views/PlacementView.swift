import SwiftUI
import SwiftData

/// Le test de niveau du moteur adaptatif (`docs/moteur-adaptatif.md`, étape 3) : le
/// vocabulaire, sur l'iPhone, puis les défis, jugés par le serveur, et le résultat à
/// valider. Chaque partie est gardée dans le passage non validé (`PlacementResult`) :
/// le test reprend où il s'était arrêté.
struct PlacementView: View {
    let pack: CurriculumPack

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStatus.self) private var server
    @State private var stage: Stage = .intro

    private enum Stage {
        case intro
        case vocabulary(VocabularyTestRun)
        case vocabularyDone(VocabularyTest.Outcome)
        case challenges(ChallengeSession)
        case result(PlacementResult, workingLevel: String)
        case completed(level: String, start: CurriculumPack.Objective?)
    }

    var body: some View {
        Group {
            switch stage {
            case .intro:
                intro
            case .vocabulary(let run):
                VocabularyTestView(run: run) { finish($0) }
            case .vocabularyDone(let outcome):
                VocabularyResultView(outcome: outcome, serverReady: server.placement != nil,
                                     redo: startVocabulary, next: startChallenges)
            case .challenges(let session):
                ChallengeView(session: session) { working in
                    withAnimation { stage = .result(session.result, workingLevel: working) }
                }
            case .result(let result, let working):
                PlacementResultView(result: result, pack: pack, proposed: working) { validate(result, level: $0) }
            case .completed(let level, let start):
                completed(level: level, start: start)
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyStyle.paper)
        .navigationTitle("Test de niveau")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: resume)
    }

    /// Un passage en cours reprend : aux défis s'il en a, sinon au résultat du vocabulaire.
    private func resume() {
        guard case .intro = stage, let draft = PlacementStore.draft(language: pack.language, in: context),
              let outcome = draft.placementDetails.vocabulary
        else { return }
        if !draft.placementDetails.challenges.isEmpty, let service = server.placement {
            stage = .challenges(ChallengeSession(result: draft, pack: pack, service: service, context: context))
        } else {
            stage = .vocabularyDone(outcome)
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Ton vocabulaire")
                    .font(.title2.weight(.bold))
                Text("Des mots espagnols s'affichent un par un, des plus courants aux plus rares. "
                     + "Réponds « Je connais » seulement si tu sais ce que le mot veut dire.")
                Text("Certains mots sont inventés. Dire oui à un mot inventé fait baisser le score : "
                     + "dans le doute, réponds non.")
                Text("Environ 80 mots, 4 minutes. Le test s'arrête plus tôt si les mots deviennent trop rares. "
                     + "Viennent ensuite des phrases à compléter ou à traduire, corrigées par le PC.")
                    .foregroundStyle(.secondary)
                Button("Commencer", action: startVocabulary)
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .padding(.top, 8)
                    .accessibilityIdentifier("placement-start")
            }
            .padding(20)
        }
    }

    private func completed(level: String, start: CurriculumPack.Objective?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Niveau \(level)")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityIdentifier("placement-completed")
                if let start {
                    Text("Ton premier objectif : \(start.title)")
                        .font(.title3)
                } else {
                    Text("Tous les objectifs sont acquis.")
                        .font(.title3)
                }
                Text("La séance du jour partira de là. Tu pourras refaire le test dans les Réglages.")
                    .foregroundStyle(.secondary)
                Button("Fermer") { dismiss() }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .accessibilityIdentifier("placement-close")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func startVocabulary() {
        stage = .vocabulary(VocabularyTestRun(pack: pack))
    }

    private func finish(_ outcome: VocabularyTest.Outcome) {
        PlacementStore.startWithVocabulary(outcome, language: pack.language, at: .now, in: context)
        withAnimation { stage = .vocabularyDone(outcome) }
    }

    private func startChallenges() {
        guard let service = server.placement,
              let draft = PlacementStore.draft(language: pack.language, in: context)
        else { return }
        let session = ChallengeSession(result: draft, pack: pack, service: service, context: context)
        withAnimation { stage = .challenges(session) }
    }

    private func validate(_ result: PlacementResult, level: String) {
        let start = try? PlacementCompletion.complete(result, workingLevel: level, pack: pack, at: .now, in: context)
        withAnimation { stage = .completed(level: level, start: start.flatMap(pack.objective)) }
    }
}

/// Un mot à la fois, deux réponses.
struct VocabularyTestView: View {
    let run: VocabularyTestRun
    let onFinish: (VocabularyTest.Outcome) -> Void

    var body: some View {
        VStack(spacing: 24) {
            ProgressView(value: run.progress)
                .tint(StudyStyle.accent)
                .accessibilityLabel("Avancement du test")
            Spacer()
            Text(run.current?.text ?? "")
                .font(.system(size: 40, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityIdentifier("vocab-test-word")
                // Le mot change : VoiceOver le relit.
                .id(run.answers.count)
                .transition(.opacity)
            Spacer()
            // L'un sous l'autre, pleine largeur : côte à côte, « Je ne connais pas »
            // passait sur deux lignes et les boutons n'avaient pas la même hauteur.
            VStack(spacing: 12) {
                Button("Je connais") { answer(true) }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .accessibilityIdentifier("vocab-test-known")
                Button {
                    answer(false)
                } label: {
                    Text("Je ne connais pas")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityIdentifier("vocab-test-unknown")
            }
            Button("Revenir au mot précédent", systemImage: "arrow.uturn.backward") { run.undo() }
                .font(.subheadline)
                .disabled(!run.canUndo)
                .opacity(run.canUndo ? 1 : 0)
        }
        .padding(20)
        .sensoryFeedback(.selection, trigger: run.answers.count)
    }

    private func answer(_ known: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { run.answer(known: known) }
        if let outcome = run.outcome { onFinish(outcome) }
    }
}

/// Le résultat du vocabulaire. Les défis viendront ensuite.
struct VocabularyResultView: View {
    let outcome: VocabularyTest.Outcome
    /// Le PC répond et juge les défis : la suite est possible.
    let serverReady: Bool
    let redo: () -> Void
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environ \(VocabularyTest.rounded(outcome.estimate).formatted()) mots")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityIdentifier("vocab-test-estimate")
                    Text("Vocabulaire de niveau \(outcome.level)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text("C'est le nombre de mots que tu reconnais parmi les 5 000 plus courants.")
                // Un pourcentage seul (« 0 % de oui ») se lisait comme le taux de oui de
                // tout le test : on compte les mots inventés en clair.
                Text(Self.pseudowordLine(outcome) + " " + Self.pseudowordMeaning(outcome))
                    .accessibilityIdentifier("vocab-test-pseudowords")
                if !outcome.isReliable {
                    Label("Beaucoup de oui aux mots inventés : l'estimation est peu sûre. "
                          + "Refais le test en ne répondant oui qu'aux mots dont tu connais le sens.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("vocab-test-unreliable")
                }
                if serverReady {
                    Text("La suite : des phrases à compléter ou à traduire, une quinzaine, de ton niveau "
                         + "vers le haut. Le PC les corrige par paquets.")
                        .foregroundStyle(.secondary)
                    Button("Continuer : les défis", action: next)
                        .buttonStyle(StudyPrimaryButtonStyle())
                        .accessibilityIdentifier("placement-challenges")
                } else {
                    Label("La suite, des phrases à compléter ou à traduire, est corrigée par le PC : "
                          + "allume-le et lance le serveur. Ce résultat est gardé d'ici là.",
                          systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                }
                Button("Refaire le test de vocabulaire", systemImage: "arrow.clockwise", action: redo)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vocab-test-redo")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// « Tu n'as dit oui à aucun des 20 mots inventés. » / « Tu as dit oui à 3 mots inventés sur 20. »
    static func pseudowordLine(_ outcome: VocabularyTest.Outcome) -> String {
        let pseudo = outcome.answers.filter(\.item.isPseudoword)
        let yes = pseudo.filter(\.known).count
        switch yes {
        case 0: return "Tu n'as dit oui à aucun des \(pseudo.count) mots inventés."
        case 1: return "Tu as dit oui à 1 mot inventé sur \(pseudo.count)."
        default: return "Tu as dit oui à \(yes) mots inventés sur \(pseudo.count)."
        }
    }

    static func pseudowordMeaning(_ outcome: VocabularyTest.Outcome) -> String {
        if outcome.falseAlarmRate == 0 {
            return "Tes « Je connais » sont fiables : l'estimation n'est pas corrigée."
        }
        return "L'estimation est corrigée en conséquence : elle retire la part de oui donnés au hasard."
    }
}
