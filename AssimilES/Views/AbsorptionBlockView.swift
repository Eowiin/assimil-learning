import SwiftUI
import SwiftData

/// Le bloc 2, « Absorption » : le texte du jour, phrase par phrase. On écoute une
/// phrase en la touchant, ou tout le texte à la suite ; la traduction se montre à la
/// demande ; les phrases de l'objectif sont marquées, les mots nouveaux en gras. Les
/// mots nouveaux passent « vus » dès que le texte est là : ils arrivent dans les
/// révisions, une carte chacun.
struct AbsorptionBlockContent: View {
    let session: StudySession
    let pack: CurriculumPack

    @Environment(\.modelContext) private var context
    @Environment(ServerStatus.self) private var server
    @Environment(AbsorptionPreparer.self) private var preparer
    @EnvironmentObject private var sessionPlayer: SessionPlayer
    @State private var player = AbsorptionPlayer()
    @State private var revealed: Set<Int> = []

    private var text: AbsorptionText? { Absorption.text(of: session) }
    private var phase: AbsorptionPreparer.Phase { preparer.phase(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let text {
                reader(text)
            } else {
                waiting
            }
        }
        .onAppear { prepareIfIdle() }
        .onDisappear { player.stop() }
        .task(id: text != nil) {
            guard let text else { return }
            Absorption.markSeen(text, in: session, ranks: pack.ranks, at: .now, in: context)
            try? context.save()
        }
    }

    // MARK: Avant le texte

    @ViewBuilder
    private var waiting: some View {
        switch phase {
        case .writing:
            progress("L'IA écrit le texte du jour…",
                     detail: "Une demi-minute environ : il est mesuré sur ton vocabulaire, et réécrit s'il le faut.")
        case .failed(let message):
            failure("Le texte n'a pas pu être écrit", message: message) { prepare() }
        default:
            if server.absorption == nil {
                Label("Le PC ne répond pas : le texte du jour attendra.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("absorption-offline")
            } else {
                progress("Préparation du texte…", detail: nil)
            }
        }
    }

    private func progress(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                Text(title).font(.headline)
            }
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("absorption-progress")
    }

    private func failure(_ title: String, message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
            if server.absorption != nil {
                Button("Réessayer", action: retry)
                    .accessibilityIdentifier("absorption-retry")
            }
        }
    }

    // MARK: Le texte

    private func reader(_ text: AbsorptionText) -> some View {
        let forms = text.newForms
        return VStack(alignment: .leading, spacing: 16) {
            voiceBar(text)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(text.sentences.enumerated()), id: \.offset) { index, sentence in
                    row(index, sentence, forms: forms, text: text)
                }
            }
            newWords(text)
        }
    }

    @ViewBuilder
    private func voiceBar(_ text: AbsorptionText) -> some View {
        switch phase {
        case .speaking(let done, let total):
            HStack(spacing: 10) {
                ProgressView()
                Text("La voix arrive… \(done)/\(total)").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("absorption-voice-progress")
        case .voiceFailed(let message):
            failure("La voix n'a pas pu être faite", message: message) { prepare() }
        default:
            if preparer.audioURL(for: session, sentence: 0) == nil, phase != .ready {
                if server.absorption != nil {
                    Button("Faire la voix du texte", systemImage: "waveform") { prepare() }
                        .accessibilityIdentifier("absorption-voice")
                } else {
                    Label("Sans le PC, le texte se lit sans sa voix.", systemImage: "speaker.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if player.continuous {
                Button("Arrêter", systemImage: "stop.fill") { player.stop() }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .accessibilityIdentifier("absorption-stop")
            } else {
                Button("Tout écouter", systemImage: "play.fill") { play(from: player.playing ?? 0, continuous: true, text) }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .accessibilityIdentifier("absorption-play-all")
            }
        }
    }

    private func row(_ index: Int, _ sentence: AbsorptionText.Sentence, forms: [String],
                     text: AbsorptionText) -> some View {
        let isPlaying = player.playing == index
        let isObjective = text.isObjectiveHit(index)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isObjective ? StudyStyle.accent : .clear)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                if isObjective {
                    Text("Objectif")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudyStyle.accent)
                }
                Text(Self.highlighted(sentence.es, forms: forms))
                    .font(.system(.title3, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("absorption-sentence-\(index)")
                if revealed.contains(index) {
                    Text(sentence.fr)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("absorption-fr-\(index)")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { play(from: index, continuous: false, text) }
            Button {
                if revealed.contains(index) { revealed.remove(index) } else { revealed.insert(index) }
            } label: {
                Image(systemName: revealed.contains(index) ? "eye.slash" : "eye")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(revealed.contains(index) ? "Cacher la traduction" : "Voir la traduction")
            .accessibilityIdentifier("absorption-reveal-\(index)")
        }
        .padding(12)
        .background(isPlaying ? StudyStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 14))
        .animation(.default, value: isPlaying)
    }

    @ViewBuilder
    private func newWords(_ text: AbsorptionText) -> some View {
        let lemmas = text.occurrences.map(\.lemma)
        if !lemmas.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Mots nouveaux", systemImage: "sparkles").font(.headline)
                Text(lemmas.joined(separator: " · "))
                Text("Ils arrivent dans tes révisions, avec leur phrase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("absorption-new-words")
        }
    }

    /// La phrase, ses mots nouveaux en gras.
    static func highlighted(_ sentence: String, forms: [String]) -> AttributedString {
        var result = AttributedString()
        var cursor = sentence.startIndex
        for range in AbsorptionText.ranges(of: forms, in: sentence) {
            result += AttributedString(String(sentence[cursor..<range.lowerBound]))
            var word = AttributedString(String(sentence[range]))
            word.inlinePresentationIntent = .stronglyEmphasized
            result += word
            cursor = range.upperBound
        }
        result += AttributedString(String(sentence[cursor...]))
        return result
    }

    // MARK: Gestes

    private func play(from index: Int, continuous: Bool, _ text: AbsorptionText) {
        sessionPlayer.pause()
        player.play(index, count: text.sentences.count, continuous: continuous) { [preparer, session] i in
            preparer.audioURL(for: session, sentence: i)
        }
    }

    private func prepareIfIdle() {
        if phase == .idle { prepare() }
    }

    private func prepare() {
        guard let service = server.absorption else { return }
        preparer.prepare(session, pack: pack, service: service, in: context)
    }
}
