import SwiftUI

/// Le détail d'un essai de prononciation, ouvert depuis le panneau du lecteur : la
/// phrase, les mots reconnus, ce que la machine a compris, le tempo et la courbe
/// d'intonation. C'est le même essai (`VoiceTrial`) que dans le lecteur : on peut s'y
/// réenregistrer, et le résultat suit en revenant.
struct PronunciationView: View {
    @ObservedObject var trial: VoiceTrial

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let step = trial.step {
                        sentence(step)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Enregistrement")
                            .font(.headline)
                        buttons
                    }
                    .studySection()
                    if trial.phase != .ready {
                        result.studySection()
                    }
                    if trial.intonation != nil || trial.intonationFailed {
                        melody.studySection()
                    }
                    Divider()
                    disclaimer
                }
                .padding(24)
            }
            .background(StudyStyle.paper)
            .navigationTitle("Ma voix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Terminé") { dismiss() }
                }
            }
        }
    }

    // MARK: - La phrase

    private func sentence(_ step: SessionStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leçon \(step.lessonNumber) · \(step.isExercise ? "exercice" : "phrase") \(step.sentenceNumber ?? 0)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reference = trial.reference {
                Text(reference)
                    .font(.title2.weight(.medium))
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
        // Alignés sur leurs libellés : le bouton d'enregistrement, plus grand,
        // décalait « Enregistrer » sous les deux autres.
        HStack(alignment: .lastTextBaseline, spacing: 18) {
            actionButton(title: "Le natif",
                         symbol: trial.recorder.playing == .native ? "stop.fill" : "play.fill",
                         enabled: trial.step?.url != nil) { trial.toggleNative() }

            recordButton

            actionButton(title: "Moi",
                         symbol: trial.recorder.playing == .mine ? "stop.fill" : "play.fill",
                         enabled: trial.myTake != nil && !trial.isRecording) { trial.toggleMine() }
        }
        .frame(maxWidth: .infinity)
    }

    private var recordButton: some View {
        VStack(spacing: 6) {
            Button {
                Task { await trial.toggleRecording() }
            } label: {
                Image(systemName: trial.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(trial.isRecording ? Color.red : StudyStyle.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trial.isRecording ? "Arrêter l’enregistrement" : "Enregistrer ma voix")
            .disabled(!trial.canRecord || trial.phase == .analysing)

            Text(trial.isRecording ? "Arrêter" : "Enregistrer")
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
            .accessibilityLabel(symbol == "stop.fill" ? "Arrêter : \(title)" : "Écouter : \(title)")
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
        switch trial.phase {
        case .ready:
            EmptyView()
        case .recording:
            Label("J'écoute…", systemImage: "waveform")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .analysing:
            Label(trial.speech.status == .installingModel ? "Installation du modèle espagnol…" : "Reconnaissance…",
                  systemImage: "waveform")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .done:
            VStack(alignment: .leading, spacing: 14) {
                Text(trial.understoodLabel)
                    .font(.headline)

                // Les mots tels qu'ils s'écrivent, ceux qui ne sont pas passés en
                // orange : c'est là qu'il faut réécouter, pas ailleurs.
                FlowText(verdicts: trial.verdicts)

                if let heard = trial.heard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("La machine a compris")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("« \(heard) »")
                            .font(.callout)
                            .italic()
                    }
                }

                if let tempo = trial.tempoLabel {
                    Label(tempo, systemImage: "metronome")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Lequel des deux moteurs a parlé : l'iPhone 11 n'a pas celui du
                // corpus, et ça se voit dans les résultats.
                if let engine = trial.speech.engine {
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
        if let intonation = trial.intonation {
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

    private var disclaimer: some View {
        Text("Les mots reconnus t’aident à repérer ce qui passe. Pour travailler ton accent, "
             + "compare ta voix à celle du natif en les réécoutant.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Les mots à la suite, qui reviennent à la ligne comme un texte. Ceux qui ne sont pas
/// passés en orange — ici comme dans les réponses dites aux exercices.
struct FlowText: View {
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
