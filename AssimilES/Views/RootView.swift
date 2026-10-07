import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("Apprendre", systemImage: "headphones") }
                .tag(0)
            LessonListView()
                .tabItem { Label("Leçons", systemImage: "books.vertical") }
                .tag(1)
            DifficultListView(onChooseLesson: { selectedTab = 1 })
                .tabItem { Label("Réviser", systemImage: "flag") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }
                .tag(3)
        }
        .tint(StudyStyle.accent)
        .task {
            // Migration : le parcours part de l'ancienne leçon réglée à la main.
            DailyCourseStore(context: context).ensureAnchor(legacyLesson: settings.currentLesson)
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var clock: DayClock
    @Environment(\.modelContext) private var context
    @Query private var marks: [DifficultSentence]
    @Query private var progress: [LessonProgress]
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @State private var chosenMode: StudyMode?
    @State private var showLessonPicker = false
    @State private var openedSession: DailySession?

    private var store: DailyCourseStore { DailyCourseStore(context: context) }

    /// Recalculé à chaque changement de jour publié par l'horloge, même app ouverte.
    private var status: DayStatus {
        DailyCourse.status(anchorUnit: anchors.first?.unit ?? min(max(1, settings.currentLesson), Manifest.shared.lessonCount),
                           anchorSetAt: anchors.first?.setAt ?? .distantPast,
                           sessions: sessions,
                           now: clock.today)
    }

    private var due: [DifficultSentence] { ReviewSchedule.due(in: marks) }

    /// La leçon proposée à l'écoute libre : celle du parcours.
    private var freeLesson: Lesson? {
        Manifest.shared.lesson(status.plan?.headlineLesson ?? Manifest.shared.lessonCount)
    }
    private var activeLesson: Lesson? { freeLesson.flatMap { SessionBuilder.activeLesson(for: $0.number) } }
    private var mode: StudyMode { chosenMode ?? (activeLesson == nil ? .shadowing : .wave) }
    private var hasResume: Bool {
        progress.contains {
            $0.lessonNumber == freeLesson?.number && $0.mode == mode.rawValue && $0.stepIndex > 0
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    weeklyActivity
                    dailyCard
                    reviews
                    if let freeLesson {
                        freeListening(freeLesson)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(StudyStyle.paper)
            .navigationTitle("Espagnol")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $openedSession) { session in
                DailySessionView(session: session)
            }
            .sheet(isPresented: $showLessonPicker) {
                CoursePositionSheet(lesson: status.plan?.headlineLesson ?? 1) { lesson in
                    store.reposition(toLesson: lesson, now: clock.now(), legacyLesson: settings.currentLesson)
                }
            }
        }
    }

    /// Les séances validées, pas le temps écouté : un jour coché est un jour où la
    /// séance a été faite jusqu'au bout.
    private var validatedDates: [Date] { sessions.compactMap(\.completedAt) }
    private var streak: Int { Streak.current(validatedOn: validatedDates, today: clock.today) }

    /// Le cercle d'un jour suit la taille du texte, dans la limite de ce que sept
    /// colonnes laissent sur un iPhone.
    @ScaledMetric(relativeTo: .caption) private var dayCircle: CGFloat = 32

    private var weeklyActivity: some View {
        let validated = Streak.days(validatedOn: validatedDates)
        return VStack(spacing: 14) {
            HStack {
                Text("Cette semaine").font(.subheadline.weight(.semibold))
                Spacer()
                Label("\(streak) j", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyStyle.accent)
                    .accessibilityLabel("\(streak) jours de suite")
            }
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { date in
                    let studied = validated.contains(Calendar.current.startOfDay(for: date))
                    let today = Calendar.current.isDate(date, inSameDayAs: clock.today)
                    VStack(spacing: 7) {
                        Text(date, format: .dateTime.weekday(.narrow))
                            .font(.caption.weight(today ? .bold : .regular))
                            .foregroundStyle(.secondary)
                        ZStack {
                            Circle().fill(studied ? StudyStyle.button : StudyStyle.surface)
                            Circle().strokeBorder(today ? StudyStyle.accent : .clear, lineWidth: 1.5)
                            if studied {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            } else {
                                Text(date, format: .dateTime.day())
                                    .font(.caption.weight(today ? .bold : .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .padding(2)
                                    .foregroundStyle(today ? StudyStyle.accent : .secondary)
                            }
                        }
                        .frame(width: min(dayCircle, 46), height: min(dayCircle, 46))
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month()))
                    .accessibilityValue(studied ? "Séance effectuée" : (today ? "Aujourd’hui" : "Pas de séance"))
                }
            }
        }
    }

    private var weekDays: [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: clock.today)?.start ?? clock.today
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: - La séance du jour

    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Ta séance").font(.title2.weight(.bold))
                Spacer()
                Button { showLessonPicker = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.medium)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Changer la leçon en cours")
            }

            switch status {
            case .ready(let plan):
                planHeader(plan)
                stageProgress(plan, progress: nil)
                startButton("Commencer la séance")
            case .inProgress(let session, let plan):
                planHeader(plan)
                stageProgress(plan, progress: session.progress)
                startButton("Reprendre : \(session.progress.current.title.lowercased())")
            case .doneToday(let session, let plan, let tomorrow):
                done(session, plan: plan, tomorrow: tomorrow)
            case .courseComplete:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Parcours terminé", systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(StudyStyle.accent)
                    Text("Les \(Manifest.shared.lessonCount) leçons et leur deuxième vague sont faites. "
                         + "Elles restent toutes accessibles dans l’onglet Leçons.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 24))
    }

    private func planHeader(_ plan: DailyPlan) -> some View {
        let number = plan.headlineLesson
        let text = LessonTextStore.text(for: number)
        return HStack(alignment: .center, spacing: 18) {
            LessonCover(number: number)
            VStack(alignment: .leading, spacing: 5) {
                Text(caption(plan))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(text?.titleES ?? "Leçon \(number)")
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let french = text?.titleFR {
                    Text(french).font(.subheadline).foregroundStyle(.secondary)
                }
                if plan.newLesson != nil, let wave = plan.waveLesson {
                    Text("Deuxième vague : leçon \(wave)")
                        .font(.caption).foregroundStyle(StudyStyle.accent)
                }
            }
        }
    }

    private func caption(_ plan: DailyPlan) -> String {
        guard let number = plan.newLesson else {
            return "Deuxième vague · leçon \(plan.headlineLesson)"
        }
        let count = Manifest.shared.lesson(number)?.dialogue.count ?? 0
        return "Leçon \(number) · \(count) phrases" + (plan.isWeeklyReview ? " · révision" : "")
    }

    /// La progression en une ligne : une barre segmentée et l'étape en cours. Les
    /// pastilles d'avant redisaient ce que la séance montre déjà, et ne menaient
    /// nulle part.
    private func stageProgress(_ plan: DailyPlan, progress: DailyProgress?) -> some View {
        let stages = plan.stages.filter { $0 != .finish }
        let current = progress?.current ?? stages.first
        let index = current.flatMap { stages.firstIndex(of: $0) }
        let label = index.map { "Étape \($0 + 1) sur \(stages.count) · \(stages[$0].title)" }
            ?? "Toutes les étapes sont faites · reste à valider"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(stages) { stage in
                    let done = progress?.completed.contains(stage) ?? false
                    Capsule()
                        .fill(done ? StudyStyle.button
                              : stage == current ? StudyStyle.button.opacity(0.4)
                              : Color(uiColor: .tertiarySystemFill))
                        .frame(height: 6)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progression de la séance")
        .accessibilityValue(label)
        .accessibilityIdentifier("stage-progress")
    }

    private func startButton(_ title: String) -> some View {
        Button {
            openedSession = store.startOrResume(now: clock.now(), legacyLesson: settings.currentLesson)
        } label: {
            Label(title, systemImage: "play.fill")
        }
        .buttonStyle(StudyPrimaryButtonStyle())
        .accessibilityIdentifier("start-session")
    }

    /// Séance validée : rien ne propose une deuxième nouvelle leçon le même jour.
    private func done(_ session: DailySession, plan: DailyPlan, tomorrow: DailyPlan?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Séance terminée pour aujourd’hui", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(StudyStyle.accent)
                .accessibilityIdentifier("today-done")
            HStack(spacing: 14) {
                LessonCover(number: tomorrow?.headlineLesson ?? plan.headlineLesson, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    if let tomorrow {
                        Text(TomorrowText.describe(tomorrow, after: plan))
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("tomorrow")
                    } else {
                        Text("C’était la dernière séance du parcours.")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(plan.newLesson.map { "Leçon \($0) validée" } ?? "Deuxième vague validée")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Retravailler cette leçon demain", isOn: Binding(
                get: { session.repeatTomorrow },
                set: { store.setRepeatTomorrow(session, $0) }))
                .font(.subheadline)
            Button("Revoir la séance") { openedSession = session }
                .font(.subheadline)
        }
    }

    private var reviews: some View {
        HStack(spacing: 14) {
            Image(systemName: due.isEmpty ? "checkmark.circle" : "flag")
                .font(.title2).foregroundStyle(StudyStyle.accent)
                .frame(width: 44, height: 44)
                .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(due.isEmpty ? "Révisions à jour" : "\(due.count) phrase\(due.count > 1 ? "s" : "") à revoir")
                    .font(.headline)
                Text(due.isEmpty ? "Tes phrases marquées reviendront ici." : "Retrouve les phrases mises de côté.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !due.isEmpty {
                NavigationLink { PlayerView(request: .review) } label: {
                    Image(systemName: "play.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Commencer les révisions")
            }
        }
    }

    /// L'écoute libre : les trois modes d'avant, sans effet sur la séance du jour.
    private func freeListening(_ lesson: Lesson) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Écoute libre").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Mode d’écoute", selection: Binding(get: { mode }, set: { chosenMode = $0 })) {
                Text("Écoute").tag(StudyMode.passive)
                Text("Répétition").tag(StudyMode.shadowing)
                Text("La vague").tag(StudyMode.wave)
            }
            .pickerStyle(.segmented)
            Text(mode.subtitle)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .wave, let activeLesson {
                Text("Révision active : leçon \(activeLesson.number)")
                    .font(.caption).foregroundStyle(StudyStyle.accent)
            }
            NavigationLink {
                PlayerView(request: .lesson(number: lesson.number, mode: mode))
            } label: {
                HStack(spacing: 14) {
                    LessonCover(number: lesson.number, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Leçon \(lesson.number)").font(.caption).foregroundStyle(.secondary)
                        Text(LessonTextStore.text(for: lesson.number)?.titleES ?? "Leçon \(lesson.number)")
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Text(hasResume ? "Reprendre" : "Écouter").font(.subheadline)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("free-listening")
        }
    }
}

/// Replacer le parcours sur une leçon. Rien ne change tant qu'on ne valide pas.
struct CoursePositionSheet: View {
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lesson: Int
    private let initialLesson: Int

    init(lesson: Int, onApply: @escaping (Int) -> Void) {
        self.onApply = onApply
        self.initialLesson = lesson
        _lesson = State(initialValue: lesson)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $lesson, in: 1...Manifest.shared.lessonCount) {
                        Text("Leçon \(lesson) sur \(Manifest.shared.lessonCount)")
                    }
                    Text(LessonTextStore.text(for: lesson)?.titleES ?? "")
                        .font(.title3.weight(.semibold))
                } footer: {
                    Text("La séance du jour repartira de cette leçon. Une séance commencée et non validée "
                         + "sera abandonnée ; les séances déjà validées restent acquises.")
                }
            }
            .navigationTitle("Leçon en cours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") {
                        onApply(lesson)
                        dismiss()
                    }
                    .disabled(lesson == initialLesson)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
