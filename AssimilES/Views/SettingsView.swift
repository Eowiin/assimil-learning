import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var clock: DayClock
    @Environment(\.modelContext) private var context
    @Environment(\.manifest) private var manifest
    @Environment(ServerStatus.self) private var server
    @Query private var events: [StudyEvent]
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @State private var showPosition = false
    @State private var backupFolder: URL?
    @State private var showBackupMover = false
    @State private var backupError: String?

    private var dailyLesson: Int? {
        DailyCourse.status(anchorUnit: anchors.first?.unit ?? settings.currentLesson,
                           anchorSetAt: anchors.first?.setAt ?? .distantPast,
                           sessions: sessions,
                           now: clock.today, manifest: manifest).plan?.headlineLesson
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        LabeledContent("Durée de la pause") {
                            Text("×\(settings.pauseFactor, format: .number.precision(.fractionLength(2)))")
                                .monospacedDigit()
                        }
                        Slider(value: $settings.pauseFactor, in: 0.8...2.5, step: 0.1)
                            .accessibilityLabel("Durée de la pause de répétition")
                    }
                    Stepper("Répétitions par phrase : \(settings.repetitionsPerSentence)",
                            value: $settings.repetitionsPerSentence, in: 1...6)
                } header: {
                    Text("Répétition")
                } footer: {
                    Text("La pause vaut la durée de la phrase multipliée par ce facteur, "
                         + "pour qu'une phrase longue laisse plus de temps qu'une courte. "
                         + "Le nombre de répétitions s'applique à l'étape Répétition de la séance du jour : "
                         + "un repère pratique, pas une règle Assimil.")
                }

                Section {
                    Toggle("Afficher la traduction d'emblée", isOn: $settings.revealTranslation)
                } header: {
                    Text("Lecture")
                } footer: {
                    Text("Sinon, le bouton Traduction de l'écran de lecture l'affiche.")
                }

                Section("Progression") {
                    Button {
                        showPosition = true
                    } label: {
                        LabeledContent("Leçon du jour") {
                            HStack(spacing: 6) {
                                Text(dailyLesson.map(String.init) ?? "Parcours terminé")
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    LabeledContent("Série") {
                        let streak = Streak.current(validatedOn: sessions.compactMap(\.completedAt), today: clock.today)
                        Text("\(streak) \(streak > 1 ? "jours" : "jour")")
                    }
                    LabeledContent("Temps total") { Text(totalLabel) }
                }

                Section {
                    TextField("nom-du-pc.reseau.ts.net", text: $settings.serverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { checkServer() }
                        .accessibilityLabel("Adresse du serveur")
                    LabeledContent("État") { serverState }
                    Button("Tester la connexion", systemImage: "arrow.clockwise") { checkServer() }
                        .disabled(settings.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
                                  || server.state == .checking)
                } header: {
                    Text("Serveur")
                } footer: {
                    Text("Le PC de la maison, joint par Tailscale, à la maison comme dehors. "
                         + "Sans lui, l'app marche comme avant : seuls les modules qui en ont besoin "
                         + "disparaissent de l'accueil.")
                }

                Section {
                    Toggle("Afficher le texte de l'IA", isOn: $settings.conversationShowsText)
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("Sinon, on écoute d'abord : un appui sur une réplique montre son texte.")
                }

                Section {
                    Button("Exporter une sauvegarde", systemImage: "externaldrive.badge.timemachine") {
                        exportBackup()
                    }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text(backupError ?? "Une copie de la progression, des phrases marquées et du temps d'étude, "
                         + "à ranger dans Fichiers. Le texte et l'audio des leçons n'en font pas partie.")
                }
            }
            .fileMover(isPresented: $showBackupMover, file: backupFolder) { result in
                // Annuler n'est pas une erreur ; le dossier reste dans le
                // répertoire temporaire, que le système vide seul.
                if case .failure(let error) = result,
                   (error as? CocoaError)?.code != .userCancelled {
                    backupError = error.localizedDescription
                }
            }
            .studyListBackground()
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPosition) {
                CoursePositionSheet(lesson: dailyLesson ?? manifest.lessonCount) { lesson in
                    DailyCourseStore(context: context, manifest: manifest)
                        .reposition(toLesson: lesson, now: clock.now(), legacyLesson: settings.currentLesson)
                }
            }
        }
    }

    @ViewBuilder
    private var serverState: some View {
        switch server.state {
        case .unset:
            Text("Aucun").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Vérification…")
            }
            .foregroundStyle(.secondary)
        case .online(let health):
            Label(health.gpu.map { "En ligne · \($0)" } ?? "En ligne", systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .green))
        case .offline(let reason):
            Label(reason, systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .red))
        }
    }

    private func checkServer() {
        Task { await server.check(address: settings.serverAddress) }
    }

    /// Le dossier est déplacé, pas copié, vers l'emplacement choisi : rien ne
    /// reste en double dans l'app.
    private func exportBackup() {
        do {
            backupFolder = try StoreBackup.make(from: context, now: clock.now())
            backupError = nil
            showBackupMover = true
        } catch {
            backupError = "Export impossible : \(error.localizedDescription)"
        }
    }

    private var totalLabel: String {
        durationLabel(StudyTime.total(events))
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? "\(total / 3600) h \((total % 3600) / 60) min" : "\(total / 60) min"
    }
}

/// Une pastille de couleur devant le texte : le voyant du serveur.
private struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 8))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            configuration.title
                .multilineTextAlignment(.trailing)
        }
    }
}
