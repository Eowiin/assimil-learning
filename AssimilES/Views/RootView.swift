import SwiftUI
import SwiftData

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Aujourd'hui", systemImage: "sun.horizon") }
            LessonListView()
                .tabItem { Label("Leçons", systemImage: "list.bullet") }
            DifficultListView()
                .tabItem { Label("À revoir", systemImage: "flag") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
    }
}

/// La séance du jour. Un seul geste doit suffire à la lancer : plus il y a
/// d'écrans avant le premier son, moins la régularité tient.
struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @Query private var days: [StudyDay]
    @Query private var marks: [DifficultSentence]

    private var due: [DifficultSentence] { ReviewSchedule.due(in: marks) }

    private var lesson: Lesson? { Manifest.shared.lesson(settings.currentLesson) }
    private var activeLesson: Lesson? { SessionBuilder.activeLesson(for: settings.currentLesson) }

    var body: some View {
        NavigationStack {
            List {
                if let lesson {
                    Section {
                        NavigationLink {
                            PlayerView(request: .lesson(number: lesson.number, mode: defaultMode))
                        } label: {
                            SessionCard(lesson: lesson,
                                        mode: defaultMode,
                                        activeLesson: activeLesson)
                        }
                    } header: {
                        Text("Séance du jour")
                    } footer: {
                        if let activeLesson {
                            Text("La vague : leçon \(lesson.number) en écoute, "
                                 + "leçon \(activeLesson.number) en répétition active.")
                        } else {
                            Text("La révision active démarre à la leçon 50.")
                        }
                    }

                    Section("Autres modes") {
                        ForEach(otherModes, id: \.self) { mode in
                            NavigationLink {
                                PlayerView(request: .lesson(number: lesson.number, mode: mode))
                            } label: {
                                ModeRow(mode: mode)
                            }
                        }
                    }
                }

                if !due.isEmpty {
                    Section {
                        NavigationLink {
                            PlayerView(request: .review)
                        } label: {
                            Label("Revoir \(due.count) phrase\(due.count > 1 ? "s" : "")",
                                  systemImage: "flag")
                        }
                    } footer: {
                        // La séance du jour est ce qui fait avancer ; la révision
                        // est ce qui empêche de reperdre. Elle a sa place ici,
                        // pas seulement dans son onglet.
                        Text("Les phrases marquées reviennent à intervalle croissant.")
                    }
                }

                Section("Régularité") {
                    LabeledContent("Série en cours") {
                        Text("\(Streak.current(from: days)) jour(s)")
                            .monospacedDigit()
                    }
                    Stepper("Leçon en cours : \(settings.currentLesson)",
                            value: $settings.currentLesson, in: 1...Manifest.shared.lessonCount)
                }
            }
            .navigationTitle("Aujourd'hui")
        }
    }

    /// À partir de la leçon 50, la vague devient le mode par défaut : c'est
    /// exactement le moment où le suivi manuel du livre devient pénible.
    private var defaultMode: StudyMode {
        activeLesson == nil ? .shadowing : .wave
    }

    private var otherModes: [StudyMode] {
        StudyMode.allCases.filter { $0 != defaultMode }
    }
}

private struct SessionCard: View {
    let lesson: Lesson
    let mode: StudyMode
    let activeLesson: Lesson?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: mode.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Leçon \(lesson.number)")
                    .font(.headline)
                Text(mode.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ModeRow: View {
    let mode: StudyMode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode.symbol)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title)
                Text(mode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
