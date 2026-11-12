import SwiftUI

/// Le récapitulatif d'une conversation : chaque phrase fautive, sa correction, mot
/// changé en couleur, et la règle en une phrase. Rien n'a coupé l'échange avant.
struct ConversationRecapView: View {
    let review: ConversationSession.Review
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
        case .done(let corrections) where corrections.isEmpty:
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
        case .done(let corrections):
            Text(corrections.count == 1 ? "Une phrase à reprendre" : "\(corrections.count) phrases à reprendre")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("recap-count")
            ForEach(Array(corrections.enumerated()), id: \.offset) { _, correction in
                card(correction)
            }
        }
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
        }
        .studySection()
        .accessibilityElement(children: .combine)
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
