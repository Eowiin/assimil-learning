import SwiftUI

/// Le récapitulatif d'une conversation : chaque phrase fautive, sa correction, mot
/// changé en couleur, et la règle en une phrase. Rien n'a coupé l'échange avant.
struct ConversationRecapView: View {
    let review: ConversationSession.Review
    /// Les phrases où l'objectif a été tenté, jugées. Nil : aucun objectif demandé.
    var objectiveUses: [ObjectiveUse]? = nil
    /// Un écrit : le texte entier corrigé, montré sous les phrases. Nil : une conversation.
    var correctedText: String? = nil
    /// Les fautes des conversations et des écrits d'avant : une faute qui revient le dit.
    var earlier = ErrorPatterns()
    /// Les temps de réaction d'une rafale. Nil : une autre conversation.
    var reflex: ReflexMeter? = nil
    let retry: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let reflex, let average = reflex.averageLabel {
                    reflexSummary(reflex, average: average)
                }
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// La vitesse de la rafale : arrivée sans attendre l'IA, elle passe en premier.
    private func reflexSummary(_ reflex: ReflexMeter, average: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Réflexe", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(StudyStyle.accent)
            Text(average)
                .accessibilityIdentifier("reflex-average")
            Text(reflex.bestStreakLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reflex-best")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studySection()
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
            if let correctedText, !corrections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ton texte corrigé")
                        .font(.title3.weight(.semibold))
                    Text(correctedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("recap-corrected-text")
                }
                .studySection()
            }
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
            Text(correctedText == nil ? "Tout ce que tu as dit était correct." : "Tout ce que tu as écrit était correct.")
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
            Text(correctedText == nil ? "Objectif du jour" : "Objectif rappelé")
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
        let written = correctedText != nil
        let diff = WordDiff.compare(said: correction.said, corrected: correction.corrected, accents: written)
        return VStack(alignment: .leading, spacing: 10) {
            line(label: written ? "Tu as écrit" : "Tu as dit", words: diff.said, mark: .removed)
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

    /// « ser/estar — déjà relevé dans 2 conversations et un écrit ». Chaque partie
    /// est omise si elle vaut zéro. Rien pour une première faute (décision 4 de
    /// `docs/module-profil.md`).
    static func recurrence(of correction: ConversationCorrection, in earlier: ErrorPatterns) -> String? {
        guard let tag = correction.tag, let pattern = earlier.pattern(for: correction),
              pattern.productions > 0 else { return nil }
        let parts = [
            count(pattern.conversations, one: "une conversation", many: "conversations"),
            count(pattern.writings, one: "un écrit", many: "écrits"),
        ].compactMap { $0 }
        return "\(tag) — déjà relevé dans \(parts.joined(separator: " et "))"
    }

    private static func count(_ n: Int, one: String, many: String) -> String? {
        n == 0 ? nil : n == 1 ? one : "\(n) \(many)"
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
