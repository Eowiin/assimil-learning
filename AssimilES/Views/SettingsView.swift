import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var clock: DayClock
    @Environment(\.modelContext) private var context
    @Query private var days: [StudyDay]
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @State private var showPosition = false

    private var dailyLesson: Int? {
        DailyCourse.status(anchorUnit: anchors.first?.unit ?? settings.currentLesson,
                           anchorSetAt: anchors.first?.setAt ?? .distantPast,
                           sessions: sessions,
                           now: clock.today).plan?.headlineLesson
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
                    Toggle("Inclure l'exercice de traduction", isOn: $settings.includeExercise)
                    Toggle("Annoncer le numéro de leçon", isOn: $settings.announceLesson)
                    Toggle("Afficher la traduction d'emblée", isOn: $settings.revealTranslation)
                } header: {
                    Text("Écoute libre")
                } footer: {
                    Text("Dans la séance du jour, les exercices ne suivent jamais le dialogue : on y passe soi-même.")
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
            }
            .studyListBackground()
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPosition) {
                CoursePositionSheet(lesson: dailyLesson ?? Manifest.shared.lessonCount) { lesson in
                    DailyCourseStore(context: context)
                        .reposition(toLesson: lesson, now: clock.now(), legacyLesson: settings.currentLesson)
                }
            }
        }
    }

    private var totalLabel: String {
        durationLabel(days.reduce(0) { $0 + $1.seconds })
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? "\(total / 3600) h \((total % 3600) / 60) min" : "\(total / 60) min"
    }
}
