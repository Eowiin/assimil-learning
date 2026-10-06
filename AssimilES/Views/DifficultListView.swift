import SwiftUI
import SwiftData

/// Les phrases marquées d'un geste pendant l'écoute, et leur retour programmé.
/// Une liste que l'usage remplit tout seul, sans effort de saisie.
struct DifficultListView: View {
    let onChooseLesson: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \DifficultSentence.markedAt, order: .reverse)
    private var marks: [DifficultSentence]

    private var due: [DifficultSentence] { ReviewSchedule.due(in: marks) }
    private var later: [DifficultSentence] {
        marks.filter { !$0.isDue }.sorted { $0.dueAt < $1.dueAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if marks.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "flag")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(StudyStyle.accent)
                            .frame(width: 88, height: 88)
                            .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 28))
                        VStack(spacing: 10) {
                            Text("Les phrases à garder")
                                .font(.title2.weight(.bold))
                            Text("Une phrase te résiste ? Marque-la avec le drapeau pendant l’écoute. Tu la retrouveras ici pour la retravailler.")
                                .font(.body).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button(action: onChooseLesson) {
                            Text("Choisir une leçon")
                        }
                        .buttonStyle(StudyPrimaryButtonStyle())
                        .padding(.top, 8)
                    }
                    .padding(28)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            if due.isEmpty {
                                Label("Rien à revoir aujourd'hui", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            } else {
                                NavigationLink {
                                    PlayerView(request: .review)
                                } label: {
                                    ReviewCard(count: due.count)
                                }
                            }
                        } footer: {
                            Text("Chaque phrase revient à intervalle croissant. "
                                 + "Pendant la révision, le drapeau la retire quand elle est acquise.")
                        }

                        if !due.isEmpty {
                            Section("À revoir maintenant") {
                                ForEach(due) { MarkRow(mark: $0) }
                                    .onDelete { delete($0, from: due) }
                            }
                        }

                        if !later.isEmpty {
                            Section("Plus tard") {
                                ForEach(later) { MarkRow(mark: $0) }
                                    .onDelete { delete($0, from: later) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .studyListBackground()
                }
            }
            .background(StudyStyle.paper)
            .navigationTitle("Réviser")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func delete(_ offsets: IndexSet, from list: [DifficultSentence]) {
        offsets.map { list[$0] }.forEach(context.delete)
    }
}

private struct ReviewCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flag.circle")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Réviser \(count) phrase\(count > 1 ? "s" : "")")
                    .font(.headline)
                Text("Chacune suivie d'une pause pour la redire")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct MarkRow: View {
    let mark: DifficultSentence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spanish ?? "Leçon \(mark.lessonNumber), phrase \(mark.sentenceNumber)")
                .font(.body)
                .lineLimit(3)
            HStack(spacing: 6) {
                Text("Leçon \(mark.lessonNumber)")
                Text("·")
                Text(mark.isExercise ? "exercice \(mark.sentenceNumber)" : "phrase \(mark.sentenceNumber)")
                if mark.reviewCount > 0 {
                    Text("·")
                    Text("\(mark.reviewCount) reprise\(mark.reviewCount > 1 ? "s" : "")")
                }
                if !mark.isDue {
                    Text("·")
                    Text(mark.dueAt, format: .relative(presentation: .named))
                }
            }
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
