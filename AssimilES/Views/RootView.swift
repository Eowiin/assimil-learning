import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var packs
    @State private var selectedTab = 0

    /// Sans paquet, rien à étudier : on le dit, au lieu de planter au lancement
    /// comme le faisait l'ancien `Manifest.shared`. L'état de l'apprenant reste
    /// intact dans SwiftData, il attend le contenu.
    var body: some View {
        if let pack = packs.assimil {
            tabs(manifest: pack.manifest)
                .environment(\.manifest, pack.manifest)
        } else {
            ContentUnavailableView {
                Label("Aucun contenu", systemImage: "shippingbox")
            } description: {
                Text("Le paquet Assimil Espagnol est introuvable, ni dans l'app ni dans ses données. "
                     + "Ta progression est conservée : elle reviendra avec le contenu.")
            }
            .accessibilityIdentifier("no-content")
        }
    }

    private func tabs(manifest: Manifest) -> some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("Aujourd'hui", systemImage: "headphones") }
                .tag(0)
            LessonListView()
                .tabItem { Label("Leçons", systemImage: "books.vertical") }
                .tag(1)
            // Pas d'onglet de révision : les phrases dues s'annoncent sur l'accueil,
            // et c'est de là qu'on les revoit.
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .tint(StudyStyle.accent)
        .task {
            // Migration : le parcours part de l'ancienne leçon réglée à la main.
            DailyCourseStore(context: context, manifest: manifest).ensureAnchor(legacyLesson: settings.currentLesson)
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var clock: DayClock
    @Environment(ServerStatus.self) private var server
    @Environment(\.modelContext) private var context
    @Environment(\.manifest) private var manifest
    /// Toutes les cartes, inactives comprises : un mot retiré ne doit pas revenir
    /// parmi les nouveaux.
    @Query private var cards: [Card]
    @Query private var sessions: [DailySession]
    @Query private var anchors: [CourseAnchor]
    @State private var openedSession: DailySession?

    private var store: DailyCourseStore { DailyCourseStore(context: context, manifest: manifest) }

    /// Recalculé à chaque changement de jour publié par l'horloge, même app ouverte.
    private var status: DayStatus {
        DailyCourse.status(anchorUnit: anchors.first?.unit ?? min(max(1, settings.currentLesson), manifest.lessonCount),
                           anchorSetAt: anchors.first?.setAt ?? .distantPast,
                           sessions: sessions,
                           now: clock.today, manifest: manifest)
    }

    // MARK: Vocabulaire

    private var vocabulary: Vocabulary? { VocabularyStore.current }

    /// Les leçons dont les mots sont proposés : validées avant aujourd'hui.
    private var vocabLessons: Set<Int> {
        VocabStudy.availableLessons(sessions: sessions, anchorUnit: anchors.first?.unit,
                                    manifest: manifest, now: clock.today)
    }

    /// Dues et nouvelles du moment. `clock.today` les fait recalculer au changement
    /// de jour ; l'heure, elle, vient de l'horloge du système (décalée en Debug).
    private var vocabCounts: (due: Int, new: Int) {
        guard let vocabulary else { return (0, 0) }
        _ = clock.today
        let now = DayClock.systemNow()
        let new = VocabStudy.newCards(vocabulary: vocabulary, lessons: vocabLessons, cards: cards,
                                      limit: VocabStudy.newRemaining(cards, now: now)).count
        return (VocabStudy.due(cards, in: vocabulary, now: now).count, new)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Une rangée de jours, compacte, puis la séance : la seule chose à faire
                // en ouvrant l'app. La série se lit dans le sous-titre, avec la date.
                VStack(alignment: .leading, spacing: 20) {
                    header
                    weeklyActivity
                    dailyCard
                    reviews
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(StudyStyle.paper)
            // La séance vient d'être validée : on le sent au retour sur l'accueil.
            .sensoryFeedback(.success, trigger: validatedDates.count)
            .navigationTitle("Aujourd'hui")
            // L'en-tête est dans la page : la flamme s'aligne sur le titre, et la barre
            // n'a plus rien à porter. Les écrans ouverts d'ici gardent la leur.
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(item: $openedSession) { session in
                DailySessionView(session: session)
            }
        }
    }

    /// Les séances validées, pas le temps écouté : un jour coché est un jour où la
    /// séance a été faite jusqu'au bout.
    private var validatedDates: [Date] { sessions.compactMap(\.completedAt) }
    private var streak: Int { Streak.current(validatedOn: validatedDates, today: clock.today) }


    /// « Aujourd'hui » et la date, la série à la flamme sur la ligne du titre. Changer
    /// de leçon, rare et lourd, se fait dans Réglages › Leçon du jour.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aujourd'hui")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(clock.today.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(streak)", systemImage: "flame.fill")
                .labelStyle(.titleAndIcon)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(streak > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Série")
                .accessibilityValue("\(streak) \(streak > 1 ? "jours" : "jour") de suite")
                .accessibilityIdentifier("streak")
        }
    }

    /// Le cercle d'un jour suit la taille du texte, dans la limite de ce que sept
    /// colonnes laissent sur un iPhone.
    @ScaledMetric(relativeTo: .caption) private var dayCircle: CGFloat = 28

    private var weeklyActivity: some View {
        let validated = Streak.days(validatedOn: validatedDates)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { date in
                    let studied = validated.contains(Calendar.current.startOfDay(for: date))
                    let today = Calendar.current.isDate(date, inSameDayAs: clock.today)
                    VStack(spacing: 5) {
                        Text(date, format: .dateTime.weekday(.narrow))
                            .font(.caption2.weight(today ? .bold : .regular))
                            .foregroundStyle(.secondary)
                        ZStack {
                            Circle().fill(studied ? StudyStyle.button : StudyStyle.surface)
                            Circle().strokeBorder(today ? StudyStyle.accent : .clear, lineWidth: 1.5)
                            if studied {
                                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            } else {
                                Text(date, format: .dateTime.day())
                                    .font(.caption2.weight(today ? .bold : .medium))
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
                    Text("Les \(manifest.lessonCount) leçons et leur deuxième vague sont faites. "
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
        let count = manifest.lesson(number)?.dialogue.count ?? 0
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

    /// Le vocabulaire du jour : toute la ligne mène à la révision. Sans rien à faire,
    /// une ligne calme qui dit d'où viennent les mots. Sans vocabulaire dans le
    /// paquet, rien.
    @ViewBuilder
    private var reviews: some View {
        if let vocabulary {
            let counts = vocabCounts
            if counts.due + counts.new == 0 {
                reviewsRow(title: "Vocabulaire à jour",
                           detail: "Les mots d'une leçon validée arrivent ici le lendemain.",
                           symbol: "checkmark.circle")
                    .accessibilityIdentifier("vocab-up-to-date")
            } else {
                NavigationLink {
                    VocabReviewView(vocabulary: vocabulary, lessons: vocabLessons)
                } label: {
                    HStack(spacing: 14) {
                        reviewsRow(title: "Vocabulaire",
                                   detail: Self.vocabDetail(due: counts.due, new: counts.new),
                                   symbol: "character.book.closed")
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("start-vocab")
            }
        }
        conversationRow
        pronunciationRow
    }

    /// La prononciation, quand le PC de la maison l'a chargée. Sinon rien, comme la
    /// conversation.
    @ViewBuilder
    private var pronunciationRow: some View {
        if let service = server.pronunciation {
            NavigationLink {
                PronunciationEntry(service: service, lessons: PronunciationDrill.lessons(available: vocabLessons))
            } label: {
                HStack(spacing: 14) {
                    reviewsRow(title: "Prononciation",
                               detail: "Cinq phrases, tes sons corrigés",
                               symbol: "mouth")
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("start-pronunciation")
        }
    }

    /// La conversation, quand le PC de la maison répond et l'a chargée. Sinon rien :
    /// pas de ligne grisée pour une fonction qu'on ne peut pas utiliser.
    @ViewBuilder
    private var conversationRow: some View {
        if let service = server.conversation {
            NavigationLink {
                ConversationView(service: service)
            } label: {
                HStack(spacing: 14) {
                    reviewsRow(title: "Conversation",
                               detail: "Parler en espagnol avec l'IA",
                               symbol: "bubble.left.and.text.bubble.right")
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("start-conversation")
        }
    }

    /// « 14 à revoir · 20 nouveaux »
    static func vocabDetail(due: Int, new: Int) -> String {
        var parts: [String] = []
        if due > 0 { parts.append("\(due) à revoir") }
        if new > 0 { parts.append("\(new) nouveau\(new > 1 ? "x" : "")") }
        return parts.joined(separator: " · ")
    }

    private func reviewsRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2).foregroundStyle(StudyStyle.accent)
                .frame(width: 44, height: 44)
                .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

}

/// Replacer le parcours sur une leçon. Rien ne change tant qu'on ne valide pas.
struct CoursePositionSheet: View {
    let onApply: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.manifest) private var manifest
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
                    Stepper(value: $lesson, in: 1...max(1, manifest.lessonCount)) {
                        Text("Leçon \(lesson) sur \(manifest.lessonCount)")
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
