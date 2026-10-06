import SwiftUI
import SwiftData

struct LessonListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var clock: DayClock
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(completed.count) leçons validées sur \(Manifest.shared.lessonCount)")
                            .font(.subheadline).foregroundStyle(.secondary)

                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                }
                Section {
                    // Consultation libre : ouvrir une leçon d'ici ne touche pas au parcours.
                    ForEach(Manifest.shared.lessons) { lesson in
                        NavigationLink {
                            PlayerView(request: .lesson(number: lesson.number, mode: .shadowing))
                        } label: {
                            LessonRow(lesson: lesson,
                                      isCompleted: completed.contains(lesson.number),
                                      isCurrent: lesson.number == currentLesson)
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
            }

            Spacer()

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
