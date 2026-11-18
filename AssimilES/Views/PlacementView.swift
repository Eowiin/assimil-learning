import SwiftUI
import SwiftData

/// Le test de niveau du moteur adaptatif (`docs/moteur-adaptatif.md`, étape 3). Pour
/// l'instant, sa première partie : le vocabulaire, sur l'iPhone, sans serveur. Le
/// résultat est gardé dans un passage non validé (`PlacementResult`), que les
/// parties suivantes compléteront.
struct PlacementView: View {
    let pack: CurriculumPack

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .intro

    private enum Stage {
        case intro
        case vocabulary(VocabularyTestRun)
        case vocabularyDone(VocabularyTest.Outcome)
    }

    var body: some View {
        Group {
            switch stage {
            case .intro:
                intro
            case .vocabulary(let run):
                VocabularyTestView(run: run) { finish($0) }
            case .vocabularyDone(let outcome):
                VocabularyResultView(outcome: outcome, redo: startVocabulary)
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyStyle.paper)
        .navigationTitle("Test de niveau")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            guard case .intro = stage,
                  let outcome = PlacementStore.draft(language: pack.language, in: context)?.placementDetails.vocabulary
            else { return }
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
                Text("Environ 80 mots, 4 minutes. Le test s'arrête plus tôt si les mots deviennent trop rares.")
                    .foregroundStyle(.secondary)
                Button("Commencer", action: startVocabulary)
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .padding(.top, 8)
                    .accessibilityIdentifier("placement-start")
            }
            .padding(20)
        }
    }

    private func startVocabulary() {
        stage = .vocabulary(VocabularyTestRun(pack: pack))
    }

    private func finish(_ outcome: VocabularyTest.Outcome) {
        PlacementStore.startWithVocabulary(outcome, language: pack.language, at: .now, in: context)
        withAnimation { stage = .vocabularyDone(outcome) }
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
    let redo: () -> Void

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
                Text("C'est le nombre de mots parmi les 5 000 plus courants que tu reconnais, "
                     + "corrigé par tes réponses aux mots inventés "
                     + "(\(Self.percent(outcome.falseAlarmRate)) de oui).")
                if !outcome.isReliable {
                    Label("Beaucoup de oui aux mots inventés : l'estimation est peu sûre. "
                          + "Refais le test en ne répondant oui qu'aux mots dont tu connais le sens.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("vocab-test-unreliable")
                }
                Text("La suite du test, des phrases à compléter ou à traduire, arrive avec la prochaine "
                     + "version de l'app. Ce résultat est gardé d'ici là.")
                    .foregroundStyle(.secondary)
                Button("Refaire le test de vocabulaire", systemImage: "arrow.clockwise", action: redo)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("vocab-test-redo")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func percent(_ rate: Double) -> String {
        rate.formatted(.percent.precision(.fractionLength(0)))
    }
}
