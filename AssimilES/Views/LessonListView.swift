import SwiftUI
import SwiftData

struct LessonListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var clock: DayClock
    @Environment(\.manifest) private var manifest
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @Query private var progress: [LessonProgress]

    /// Les leçons validées dans le parcours. Une fin d'écoute ne compte pas.
    private var completed: Set<Int> {
        Set(sessions.filter(\.isValidated).compactMap { Curriculum.plan(unit: $0.unit, manifest: manifest)?.newLesson })
    }

    private var currentLesson: Int? {
        DailyCourse.status(anchorUnit: anchors.first?.unit ?? settings.currentLesson,
                           anchorSetAt: anchors.first?.setAt ?? .distantPast,
                           sessions: sessions,
                           now: clock.today, manifest: manifest).plan?.newLesson
    }

    /// Une écoute de cette leçon s'est arrêtée en route. Les reprises des anciens
    /// modes (Répétition, La vague) ne valent pas pour l'écoute : elles sont ignorées.
    private func canResume(_ number: Int) -> Bool {
        progress.contains {
            $0.lessonNumber == number && $0.mode == StudyMode.passive.rawValue && $0.stepIndex > 0
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        // L'écoute libre, sans effet sur la séance du jour.
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(completed.count) \(completed.count > 1 ? "leçons validées" : "leçon validée") sur \(manifest.lessonCount)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    Section {
                        // Consultation libre : ouvrir une leçon d'ici ne touche pas au parcours.
                        ForEach(manifest.lessons) { lesson in
                            NavigationLink {
                                LessonPage(lesson: lesson, canResume: canResume(lesson.number))
                            } label: {
                                LessonRow(lesson: lesson,
                                          isCompleted: completed.contains(lesson.number),
                                          isCurrent: lesson.number == currentLesson,
                                          canResume: canResume(lesson.number))
                            }
                            .id(lesson.number)
                        }
                    }
                }
                .listStyle(.plain)
                .studyListBackground()
                .navigationTitle("Leçons")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Cent leçons : un geste pour retrouver celle du parcours.
                    if let currentLesson {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                withAnimation { proxy.scrollTo(currentLesson, anchor: .center) }
                            } label: {
                                Label("Aller à la leçon en cours", systemImage: "scope")
                            }
                            .accessibilityIdentifier("jump-current")
                        }
                    }
                }
            }
        }
    }
}

/// La page d'une leçon : son texte complet — espagnol, prononciation, traduction,
/// notes —, chaque phrase réécoutable, et l'écoute de la leçon d'un trait.
/// Avant, une leçon ouvrait directement le lecteur, et ce texte n'existait que
/// pendant l'étape Compréhension de la séance du jour.
struct LessonPage: View {
    let lesson: Lesson
    let canResume: Bool

    @EnvironmentObject private var player: SessionPlayer

    var body: some View {
        let text = LessonTextStore.text(for: lesson.number)
        ComprehensionView(lesson: lesson,
                          text: text,
                          content: LessonContent.comprehension(text),
                          reviewContent: LessonContent.reviewSummary(lesson, text))
            .safeAreaBar(edge: .bottom) {
                NavigationLink {
                    PlayerView(request: .lesson(number: lesson.number, mode: .passive))
                } label: {
                    Label(canResume ? "Reprendre l'écoute" : "Écouter la leçon", systemImage: "headphones")
                }
                .buttonStyle(StudyPrimaryButtonStyle())
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .accessibilityIdentifier("lesson-listen")
            }
            .background(StudyStyle.paper)
            .navigationTitle("Leçon \(lesson.number)")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                // Une phrase lancée d'ici ne continue pas une fois la page quittée.
                if case .excerpt = player.request { player.pause() }
            }
    }
}

private struct LessonRow: View {
    let lesson: Lesson
    let isCompleted: Bool
    let isCurrent: Bool
    let canResume: Bool

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
