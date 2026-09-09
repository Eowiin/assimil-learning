import SwiftUI
import SwiftData

/// Les phrases marquées d'un geste pendant l'écoute. C'est le socle du futur SRS :
/// une liste que l'usage remplit tout seul, sans effort de saisie.
struct DifficultListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DifficultSentence.markedAt, order: .reverse)
    private var marks: [DifficultSentence]

    var body: some View {
        NavigationStack {
            Group {
                if marks.isEmpty {
                    ContentUnavailableView(
                        "Aucune phrase marquée",
                        systemImage: "flag",
                        description: Text("Pendant l'écoute, le drapeau met de côté une phrase qui résiste.")
                    )
                } else {
                    List {
                        ForEach(marks) { mark in
                            MarkRow(mark: mark)
                        }
                        .onDelete { offsets in
                            offsets.map { marks[$0] }.forEach(context.delete)
                        }
                    }
                }
            }
            .navigationTitle("À revoir")
        }
    }
}

private struct MarkRow: View {
    let mark: DifficultSentence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(spanish ?? "Leçon \(mark.lessonNumber), phrase \(mark.sentenceNumber)")
                .lineLimit(2)
            Text("Leçon \(mark.lessonNumber) · phrase \(mark.sentenceNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var spanish: String? {
        let text = LessonTextStore.text(for: mark.lessonNumber)
        return mark.isExercise
            ? text?.exerciseSentence(mark.sentenceNumber)?.es
            : text?.sentence(mark.sentenceNumber)?.es
    }
}
