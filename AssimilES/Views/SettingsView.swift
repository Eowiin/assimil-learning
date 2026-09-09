import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: SessionPlayer
    @Query private var days: [StudyDay]

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
                    }
                } header: {
                    Text("Répétition")
                } footer: {
                    Text("La pause vaut la durée de la phrase multipliée par ce facteur, "
                         + "pour qu'une phrase longue laisse plus de temps qu'une courte.")
                }

                Section("Contenu de la séance") {
                    Toggle("Inclure l'exercice de traduction", isOn: $settings.includeExercise)
                    Toggle("Annoncer le numéro de leçon", isOn: $settings.announceLesson)
                    Toggle("Afficher la traduction d'emblée", isOn: $settings.revealTranslation)
                }

                Section("Progression") {
                    Stepper("Leçon en cours : \(settings.currentLesson)",
                            value: $settings.currentLesson, in: 1...Manifest.shared.lessonCount)
                    LabeledContent("Série") { Text("\(Streak.current(from: days)) jour(s)") }
                    LabeledContent("Temps total") { Text(totalLabel) }
                }

                Section {
                    LabeledContent("Leçons", value: "\(Manifest.shared.lessonCount)")
                    LabeledContent("Phrases", value: "\(Manifest.shared.sentenceCount)")
                    LabeledContent("Audio", value: durationLabel(Manifest.shared.totalDuration))
                    LabeledContent("Leçons avec texte espagnol", value: "\(lessonsWithText)")
                    LabeledContent("Leçons avec traduction", value: "\(lessonsWithTranslation)")
                } header: {
                    Text("Contenu embarqué")
                } footer: {
                    Text("Usage strictement personnel. L'espagnol vient de la transcription "
                         + "des enregistrements ; la traduction, la prononciation figurée et "
                         + "les notes viennent du livre et se complètent leçon par leçon.")
                }
            }
            .navigationTitle("Réglages")
        }
    }

    private var lessonsWithText: Int {
        Manifest.shared.lessons.count { LessonTextStore.hasText(for: $0.number) }
    }

    private var lessonsWithTranslation: Int {
        Manifest.shared.lessons.count { LessonTextStore.hasTranslation(for: $0.number) }
    }

    private var totalLabel: String {
        durationLabel(days.reduce(0) { $0 + $1.seconds })
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? "\(total / 3600) h \((total % 3600) / 60) min" : "\(total / 60) min"
    }
}
