import SwiftUI

/// L'essai de prononciation sur une phrase : entendre le natif, s'enregistrer, se
/// réécouter, et voir ce que la reconnaissance a compris.
///
/// **Ce que cet écran affirme, et ce qu'il n'affirme pas.** Il ne note pas un
/// accent — aucune API d'Apple ne le fait. Il dit si les mots passent, ce qui est
/// vérifiable et déjà utile : c'est le même contrôle qui, sur le corpus, a fait
/// ressortir `Ejem` comme le seul mot que la machine manque. Le reste est laissé à
/// l'oreille, d'où la réécoute côte à côte.
struct PronunciationView: View {
    let step: SessionStep

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: SessionPlayer
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var speech = SpeechCheck()

    @State private var verdicts: [WordVerdict] = []
    @State private var myDuration: Double = 0
    @State private var intonation: Intonation?
    @State private var intonationFailed = false

    private var reference: String? { step.sentenceText?.es }
    private var key: String? { step.markKey }
    private var myTake: URL? {
        guard let key, VoiceRecorder.exists(for: key) else { return nil }
        return VoiceRecorder.url(for: key)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sentence
                    buttons
                    if !verdicts.isEmpty || speech.status != .idle {
                        Divider()
                        result
                    }
                    if intonation != nil || intonationFailed {
                        Divider()
                        melody
                    }
                    Divider()
                    disclaimer
                }
                .padding(24)
            }
            .navigationTitle("Prononciation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Terminé") { dismiss() }
                }
            }
        }
        .onAppear {
            // La séance rend la sortie audio : le micro a besoin d'une autre
            // catégorie de session, et deux moteurs ne peuvent pas la partager.
            player.releaseAudio()
            recorder.takeOver()
            myDuration = myTake.map(VoiceRecorder.duration) ?? 0
        }
        .onDisappear {
            recorder.handBack()
        }
    }

    // MARK: - La phrase

    private var sentence: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leçon \(step.lessonNumber) · \(step.isExercise ? "exercice" : "phrase") \(step.sentenceNumber ?? 0)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reference {
                Text(reference)
                    .font(.title3)
            } else {
                Text("Texte non disponible pour cette phrase.")
                    .foregroundStyle(.secondary)
            }

            if let fr = step.sentenceText?.fr {
                Text(fr)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Les commandes

    private var buttons: some View {
        HStack(spacing: 18) {
            actionButton(title: "Le natif",
                         symbol: recorder.playing == .native ? "stop.fill" : "play.fill",
                         enabled: step.url != nil) {
                if recorder.playing == .native {
                    recorder.stopPlayback()
                } else if let url = step.url {
                    recorder.play(url, as: .native)
                }
            }

            recordButton

            actionButton(title: "Moi",
                         symbol: recorder.playing == .mine ? "stop.fill" : "play.fill",
                         enabled: myTake != nil) {
                if recorder.playing == .mine {
                    recorder.stopPlayback()
                } else if let url = myTake {
                    recorder.play(url, as: .mine)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var recordButton: some View {
        VStack(spacing: 6) {
            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(reference == nil || key == nil)

            Text(recorder.isRecording ? "J'écoute" : "Enregistrer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func actionButton(title: String, symbol: String,
                              enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - Le résultat

    @ViewBuilder
    private var result: some View {
        switch speech.status {
        case .idle:
            EmptyView()
        case .installingModel:
            Label("Installation du modèle espagnol…", systemImage: "arrow.down.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .working:
            Label("Reconnaissance…", systemImage: "waveform")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .done(let heard):
            VStack(alignment: .leading, spacing: 14) {
                Text(understoodLabel)
                    .font(.headline)

                // Les mots tels qu'ils s'écrivent, ceux qui ne sont pas passés en
                // orange : c'est là qu'il faut réécouter, pas ailleurs.
                FlowText(verdicts: verdicts)

                VStack(alignment: .leading, spacing: 4) {
                    Text("La machine a compris")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("« \(heard) »")
                        .font(.callout)
                        .italic()
                }

                if let tempo = tempoLabel {
                    Label(tempo, systemImage: "metronome")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Lequel des deux moteurs a parlé : l'iPhone 11 n'a pas celui du
                // corpus, et ça se voit dans les résultats.
                if let engine = speech.engine {
                    Text("Reconnu par \(engine.label)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - La mélodie

    @ViewBuilder
    private var melody: some View {
        if let intonation {
            VStack(alignment: .leading, spacing: 12) {
                Text(intonation.verdict)
                    .font(.headline)

                IntonationChart(intonation: intonation)

                Text(String(format: "Écart médian : %.2f demi-ton", intonation.gapSemitones))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Pas assez de voix pour lire la mélodie — la phrase est trop courte, "
                  + "ou l'enregistrement trop faible.",
                  systemImage: "waveform.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var understoodLabel: String {
        let ok = verdicts.filter(\.isUnderstood).count
        let total = verdicts.count
        if total > 0, ok == total { return "Tous les mots sont passés" }
        return "\(ok) mot\(ok > 1 ? "s" : "") sur \(total) sont passés"
    }

    /// Le tempo compare deux durées, ce qui est mesurable — contrairement à un
    /// jugement sur l'accent. Assimil se dit lentement au début : c'est un repère
    /// utile, pas une faute.
    private var tempoLabel: String? {
        guard myDuration > 0, step.duration > 0 else { return nil }
        let ratio = myDuration / step.duration
        let percent = Int(((ratio - 1) * 100).rounded())
        if abs(percent) <= 15 { return "Même tempo que le natif" }
        return percent > 0
            ? "\(percent) % plus lent que le natif"
            : "\(-percent) % plus rapide que le natif"
    }

    private var disclaimer: some View {
        Text("La reconnaissance dit si tes mots **passent**, pas si ton accent est bon : "
             + "aucune évaluation de prononciation n'existe côté Apple. Pour l'accent, "
             + "c'est la réécoute côte à côte qui tranche.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    /// Le calcul de hauteur est du signal, pas de l'interface : il part sur une
    /// tâche détachée pour ne pas figer l'écran le temps de la phrase.
    private func compareMelody(mine url: URL) async {
        guard let nativeURL = step.url else { intonationFailed = true; return }
        let result = await Task.detached(priority: .userInitiated) { () -> Intonation? in
            guard let native = PitchTracker.track(nativeURL),
                  let mine = PitchTracker.track(url)
            else { return nil }
            return IntonationComparer.compare(native: native, mine: mine)
        }.value
        intonation = result
        intonationFailed = result == nil
    }

    private func toggleRecording() async {
        guard let key, let reference else { return }

        if recorder.isRecording {
            guard let url = recorder.stopRecording() else { return }
            myDuration = VoiceRecorder.duration(of: url)
            await compareMelody(mine: url)
            if let heard = await speech.recognize(url) {
                verdicts = SpanishMatch.compare(reference: reference, heard: heard)
            } else {
                verdicts = []
            }
        } else {
            verdicts = []
            intonation = nil
            intonationFailed = false
            speech.reset()
            await recorder.startRecording(key: key)
        }
    }
}

/// Les mots à la suite, qui reviennent à la ligne comme un texte.
private struct FlowText: View {
    let verdicts: [WordVerdict]

    var body: some View {
        // `Text` concaténés : le retour à la ligne reste celui d'un paragraphe,
        // là où une grille de vues couperait les mots n'importe où.
        verdicts.reduce(Text("")) { partial, verdict in
            partial + coloured(verdict) + Text(" ")
        }
        .font(.title3)
    }

    private func coloured(_ verdict: WordVerdict) -> Text {
        verdict.isUnderstood
            ? Text(verdict.word)
            : Text(verdict.word).foregroundColor(.orange)
    }
}
