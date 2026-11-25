import SwiftUI

/// Le diagnostic des sons du placement : une phrase, le micro, et la suivante. Pas de
/// natif à imiter ni de correction : c'est un diagnostic, le bilan est au résultat.
struct SoundCheckView: View {
    let check: SoundCheck
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let sentence = check.current {
                        Text("Phrase \(check.index + 1) sur \(check.sentences.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("sounds-progress")
                        Text(sentence)
                            .font(.system(.title, design: .serif))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityIdentifier("sounds-sentence")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            controls
        }
        .task { check.open() }
        .onDisappear { check.close() }
        .onChange(of: check.phase, initial: true) {
            if check.phase == .finished { onFinish() }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            status
            HStack(spacing: 24) {
                if check.phase == .recording {
                    Button("Annuler", systemImage: "xmark") { check.cancelRecording() }
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
        let recording = check.phase == .recording
        let busy = check.phase == .judging || isFailed
        return Button {
            Task { await check.toggleMic() }
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
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
        .sensoryFeedback(.start, trigger: recording)
        .accessibilityLabel(recording ? "Envoyer" : "Lire la phrase")
        .accessibilityIdentifier("sounds-mic")
    }

    private var isFailed: Bool {
        if case .failed = check.phase { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch check.phase {
        case .ready:
            hint("Touche le micro, lis la phrase, touche pour envoyer")
        case .recording:
            hint("Je t'écoute… touche pour envoyer")
        case .judging:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("J'écoute tes sons…").foregroundStyle(.secondary)
            }
        case .micDenied:
            hint("Le micro est refusé : autorise-le dans Réglages › Assimil")
        case .failed(let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Renvoyer", systemImage: "arrow.clockwise") { Task { await check.retry() } }
                        .accessibilityIdentifier("sounds-retry")
                    Button("Passer la phrase") { check.skip() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
        case .finished:
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
}
