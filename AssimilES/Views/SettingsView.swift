import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var clock: DayClock
    @Environment(\.modelContext) private var context
    @Environment(\.manifest) private var manifest
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
