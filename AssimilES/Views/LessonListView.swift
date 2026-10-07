import SwiftUI
import SwiftData

struct LessonListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var clock: DayClock
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @Query private var progress: [LessonProgress]

    /// Les leçons validées dans le parcours. Une fin d'écoute ne compte pas.
    private var completed: Set<Int> {
        Set(sessions.filter(\.isValidated).compactMap { Curriculum.plan(unit: $0.unit)?.newLesson })
    }

    private var currentLesson: Int? {
        DailyCourse.status(anchorUnit: anchors.first?.unit ?? settings.currentLesson,
                           anchorSetAt: anchors.first?.setAt ?? .distantPast,
                           sessions: sessions,
                           now: clock.today).plan?.newLesson
    }

    /// Une écoute de cette leçon, dans ce mode, s'est arrêtée en route.
    private func canResume(_ number: Int) -> Bool {
        progress.contains {
            $0.lessonNumber == number && $0.mode == settings.freeListeningMode.rawValue && $0.stepIndex > 0
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // L'écoute libre : ses trois modes, sans effet sur la séance du jour.
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode d’écoute", selection: $settings.freeListeningMode) {
                            Text("Écoute").tag(StudyMode.passive)
                            Text("Répétition").tag(StudyMode.shadowing)
                            Text("La vague").tag(StudyMode.wave)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("listening-mode")
                        Text(settings.freeListeningMode.subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(completed.count) \(completed.count > 1 ? "leçons validées" : "leçon validée") sur \(Manifest.shared.lessonCount)")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    // Consultation libre : ouvrir une leçon d'ici ne touche pas au parcours.
                    ForEach(Manifest.shared.lessons) { lesson in
                        NavigationLink {
                            PlayerView(request: .lesson(number: lesson.number, mode: settings.freeListeningMode))
                        } label: {
                            LessonRow(lesson: lesson,
                                      isCompleted: completed.contains(lesson.number),
                                      isCurrent: lesson.number == currentLesson,
                                      canResume: canResume(lesson.number),
                                      waveLesson: settings.freeListeningMode == .wave
                                        ? SessionBuilder.activeLesson(for: lesson.number)?.number : nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .studyListBackground()
            .navigationTitle("Leçons")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct LessonRow: View {
    let lesson: Lesson
    let isCompleted: Bool
    let isCurrent: Bool
    let canResume: Bool
    /// En mode « La vague » : la leçon révisée à la suite.
    let waveLesson: Int?

    var body: some View {
        HStack(spacing: 12) {
            LessonCover(number: lesson.number, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(LessonTextStore.text(for: lesson.number)?.titleES ?? "Leçon \(lesson.number)")
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent {
                    Text("En cours").font(.caption.weight(.semibold)).foregroundStyle(StudyStyle.accent)
                }
                if let waveLesson {
                    Text("Puis la leçon \(waveLesson) en révision").font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if canResume {
                Text("Reprendre").font(.caption).foregroundStyle(StudyStyle.accent)
            }
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(StudyStyle.accent)
                    .accessibilityLabel("Leçon validée")
            }
        }
        .padding(.vertical, 8)
    }

    private var details: String {
        var parts = ["\(lesson.dialogue.count) phrases", durationLabel]
        if lesson.isReview { parts.append("révision") }
        if !LessonTextStore.hasText(for: lesson.number) {
            parts.append("audio seul")
        } else if !LessonTextStore.hasTranslation(for: lesson.number) {
            parts.append("espagnol seul")
        }
        return parts.joined(separator: " · ")
    }

    private var durationLabel: String {
        let seconds = Int(lesson.dialogueDuration.rounded())
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
