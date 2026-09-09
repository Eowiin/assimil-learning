import SwiftUI
import SwiftData

struct LessonListView: View {
    @Query private var progress: [LessonProgress]

    private var completed: Set<Int> {
        Set(progress.filter { $0.completedAt != nil }.map(\.lessonNumber))
    }

    var body: some View {
        NavigationStack {
            List(Manifest.shared.lessons) { lesson in
                NavigationLink {
                    PlayerView(request: .lesson(number: lesson.number, mode: .shadowing))
                } label: {
                    LessonRow(lesson: lesson, isCompleted: completed.contains(lesson.number))
                }
            }
            .navigationTitle("Leçons")
        }
    }
}

private struct LessonRow: View {
    let lesson: Lesson
    let isCompleted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(lesson.number)")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(LessonTextStore.text(for: lesson.number)?.titleES ?? "Leçon \(lesson.number)")
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(lesson.dialogue.count) phrases")
                    Text("·")
                    Text(durationLabel)
                    if lesson.isReview {
                        Text("·")
                        Text("révision")
                    }
                    if !LessonTextStore.hasText(for: lesson.number) {
                        Text("·")
                        Text("audio seul")
                    } else if !LessonTextStore.hasTranslation(for: lesson.number) {
                        Text("·")
                        Text("espagnol seul")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var durationLabel: String {
        let seconds = Int(lesson.dialogueDuration.rounded())
        return "\(seconds / 60) min \(seconds % 60) s"
    }
}
