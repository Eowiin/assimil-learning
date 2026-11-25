import SwiftUI

/// Le haut-parleur d'une phrase du bloc 1 : la voix gardée (`VoiceCache`), sinon
/// demandée au PC sur-le-champ. Grisé quand elle n'est pas là et que le PC ne répond
/// pas.
struct VoiceButton: View {
    let text: String
    let player: VoicePlayer
    /// Appelé avant de jouer : un autre lecteur se tait.
    var willPlay: () -> Void = {}

    @Environment(VoicePreparer.self) private var voices
    @Environment(ServerStatus.self) private var server

    var body: some View {
        let cached = voices.url(for: text)
        let isPlaying = cached != nil && player.playing == cached
        Button {
            if isPlaying { return player.stop() }
            Task { await play() }
        } label: {
            Group {
                if voices.isFetching(text) {
                    ProgressView()
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2")
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyStyle.accent)
        .disabled(cached == nil && server.absorption == nil)
        .accessibilityLabel(isPlaying ? "Arrêter" : "Écouter la phrase")
        .accessibilityIdentifier("voice-play")
    }

    private func play() async {
        var url = voices.url(for: text)
        if url == nil, let service = server.absorption {
            url = await voices.fetch(text, service: service)
        }
        guard let url else { return }
        willPlay()
        player.play(url)
    }
}
