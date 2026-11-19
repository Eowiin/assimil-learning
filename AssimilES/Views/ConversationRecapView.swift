import SwiftUI

/// Le récapitulatif d'une conversation : chaque phrase fautive, sa correction, mot
/// changé en couleur, et la règle en une phrase. Rien n'a coupé l'échange avant.
struct ConversationRecapView: View {
    let review: ConversationSession.Review
    /// Les phrases où l'objectif a été tenté, jugées. Nil : aucun objectif demandé.
    var objectiveUses: [ObjectiveUse]? = nil
    /// Les fautes des conversations d'avant : une faute qui revient le dit.
    var earlier = ErrorPatterns(conversations: [])
    let retry: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch review {
        case .notStarted, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("L'IA relit tes phrases…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let reason):
            VStack(spacing: 12) {
                Text(reason)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Réessayer", systemImage: "arrow.clockwise") { Task { await retry() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("recap-retry")
                Text("La conversation est gardée sur l'iPhone, même sans récapitulatif.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .done(let corrections):
            if let objectiveUses { objective(objectiveUses) }
            if corrections.isEmpty { clean } else { list(corrections) }
        }
    }

    private var clean: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(StudyStyle.accent)
            Text("Aucune faute relevée")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("recap-clean")
            Text("Tout ce que tu as dit était correct.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    @ViewBuilder
    private func list(_ corrections: [ConversationCorrection]) -> some View {
        Text(corrections.count == 1 ? "Une phrase à reprendre" : "\(corrections.count) phrases à reprendre")
            .font(.title3.weight(.semibold))
            .accessibilityIdentifier("recap-count")
        ForEach(Array(corrections.enumerated()), id: \.offset) { _, correction in
            card(correction)
        }
    }

    /// L'objectif du jour : chaque phrase où il a été tenté, réussie ou non, et le mot
    /// du correcteur. Une conversation ne compte qu'une réussite au plus.
    private func objective(_ uses: [ObjectiveUse]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Objectif du jour")
                .font(.title3.weight(.semibold))
            if uses.isEmpty {
                Text("Tu ne l'as pas employé cette fois.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recap-objective-none")
            }
            ForEach(Array(uses.enumerated()), id: \.offset) { _, use in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: use.valid ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(use.valid ? StudyStyle.accent : .red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(use.said)
                        Text(use.analysis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("recap-objective-use")
            }
        }
        .studySection()
    }

    private func card(_ correction: ConversationCorrection) -> some View {
        let diff = WordDiff.compare(said: correction.said, corrected: correction.corrected)
        return VStack(alignment: .leading, spacing: 10) {
            line(label: "Tu as dit", words: diff.said, mark: .removed)
            line(label: "Correct", words: diff.corrected, mark: .added)
            Text(correction.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text = Self.recurrence(of: correction, in: earlier) {
                Label(text, systemImage: "arrow.counterclockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudyStyle.accent)
                    .accessibilityIdentifier("recap-recurring")
            }
        }
        .studySection()
        .accessibilityElement(children: .combine)
    }

    /// « ser/estar — déjà relevé dans 2 conversations ». Rien pour une première
    /// faute (décision 4 de `docs/module-profil.md`).
    static func recurrence(of correction: ConversationCorrection, in earlier: ErrorPatterns) -> String? {
        guard let tag = correction.tag, let pattern = earlier.pattern(for: correction) else { return nil }
        let count = pattern.conversations == 1 ? "une conversation" : "\(pattern.conversations) conversations"
        return "\(tag) — déjà relevé dans \(count)"
    }

    private enum Mark { case removed, added }

    private func line(label: String, words: [WordDiff.Word], mark: Mark) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            styled(words, mark: mark)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Les mots changés : barrés en rouge dans la phrase dite, en gras dans la
    /// corrigée.
    private func styled(_ words: [WordDiff.Word], mark: Mark) -> Text {
        var text = AttributedString()
        for (index, word) in words.enumerated() {
            var piece = AttributedString(word.text)
            if word.changed {
                switch mark {
                case .removed:
                    piece.foregroundColor = .red
                    piece.strikethroughStyle = .single
                case .added:
                    piece.foregroundColor = StudyStyle.accent
                    piece.inlinePresentationIntent = .stronglyEmphasized
                }
            }
            text += piece
            if index < words.count - 1 { text += AttributedString(" ") }
        }
        return Text(text)
    }
}
