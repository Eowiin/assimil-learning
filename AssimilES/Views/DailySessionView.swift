import SwiftUI
import SwiftData

/// La séance du jour, étape par étape.
///
/// Chaque étape se termine par un geste — « Passer à la compréhension », « Passer
/// aux exercices » — et l'avancement est sauvegardé à chaque geste : l'app peut être
/// fermée à n'importe quelle étape, la séance reprend là. La leçon n'est validée
/// qu'à la dernière étape, quand toutes les autres sont faites.
struct DailySessionView: View {
    let session: DailySession

    @EnvironmentObject private var player: SessionPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var clock: DayClock
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Une écoute par langue de réponse : le français pour traduire, l'espagnol pour
    /// la deuxième vague. Chacune garde son modèle prêt d'une phrase à l'autre.
    @StateObject private var frenchListener = AnswerListener(locale: Locale(identifier: "fr-FR"))
    @StateObject private var spanishListener = AnswerListener(locale: Locale(identifier: "es-ES"))

    private var plan: DailyPlan? { Curriculum.plan(unit: session.unit) }
    private var store: DailyCourseStore { DailyCourseStore(context: context) }

    /// Toute modification de l'avancement est écrite aussitôt.
    private var progress: Binding<DailyProgress> {
        Binding(get: { session.progress },
                set: { session.progress = $0; store.save() })
    }

    var body: some View {
        Group {
            if let plan {
                stageView(session.progress.current, plan: plan)
                    // Une étape = une vue neuve : le lecteur de la découverte
                    // doit disparaître pour que celui de la répétition démarre.
                    .id(session.progress.current)
                    .frame(maxHeight: .infinity)
                    .navigationTitle(title(plan))
                    .navigationSubtitle(stageSubtitle(plan))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { stageMenu(plan) }
                    }
            } else {
                ContentUnavailableView("Séance introuvable", systemImage: "questionmark.circle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(StudyStyle.paper)
        .toolbar(.hidden, for: .tabBar)
        .onDisappear {
            AudioLog.info("\(#fileID) disparaît")
            player.pause()
            StudyTime.record(player.takeUnrecordedSeconds(), in: context, now: clock.now())
            store.save()
        }
    }

    /// Les étapes affichées : la fin de séance n'en est une que quand on y est, il
    /// reste alors quelque chose à faire avant de valider.
    private func visibleStages(_ plan: DailyPlan) -> [DailyStage] {
        plan.stages.filter { $0 != .finish || session.progress.current == .finish }
    }

    /// L'étape en cours, sous le titre. Son nom seul : avec la position (« Étape 3 sur
    /// 5 · … »), il se tronquait à côté des trois boutons de la barre, et le menu
    /// Étapes dit déjà où l'on en est.
    private func stageSubtitle(_ plan: DailyPlan) -> String {
        session.progress.current.title
    }

    /// Revenir à une étape déjà ouverte. Les suivantes restent fermées tant que
    /// celle d'avant n'est pas faite.
    private func stageMenu(_ plan: DailyPlan) -> some View {
        let progress = session.progress
        return Menu {
            ForEach(visibleStages(plan)) { stage in
                Button {
                    self.progress.wrappedValue.open(stage, in: plan.stages)
                } label: {
                    Label(stage.title, systemImage: progress.completed.contains(stage) ? "checkmark.circle.fill"
                          : stage == progress.current ? "circle.inset.filled" : "circle")
                }
                .disabled(!progress.isReachable(stage, in: plan.stages))
            }
        } label: {
            Label("Étapes", systemImage: "list.number")
        }
        .accessibilityIdentifier("stage-menu")
    }

    private func title(_ plan: DailyPlan) -> String {
        if let lesson = plan.newLesson { return "Leçon \(lesson)" }
        return "Deuxième vague"
    }

    // MARK: - Étapes

    @ViewBuilder
    private func stageView(_ stage: DailyStage, plan: DailyPlan) -> some View {
        switch stage {
        case .discovery:
            audioStage(.discovery, audio: .discovery, plan: plan)
        case .comprehension:
            comprehension(plan)
        case .repetition:
            audioStage(.repetition, audio: .repetition(times: max(1, settings.repetitionsPerSentence)), plan: plan)
        case .translation:
            translation(plan)
        case .completion:
            completion(plan)
        case .secondWave:
            secondWave(plan)
        case .finish:
            finish(plan)
        }
    }

    @ViewBuilder
    private func audioStage(_ stage: DailyStage, audio: DailyAudio, plan: DailyPlan) -> some View {
        if let lesson = plan.newLesson {
            PlayerView(request: .daily(lessonNumber: lesson, audio: audio),
                       resumeSentence: session.progress.audioSentence(for: stage),
                       onSentenceChange: { progress.wrappedValue.recordAudio(stage, sentence: $0) },
                       stageAction: StageAction(title: nextTitle(after: stage, plan: plan),
                                                symbol: nextSymbol(after: stage, plan: plan)) {
                           completeStage(stage, plan: plan)
                       })
        }
    }

    @ViewBuilder
    private func comprehension(_ plan: DailyPlan) -> some View {
        if let number = plan.newLesson, let lesson = Manifest.shared.lesson(number) {
            let text = LessonTextStore.text(for: number)
            let content = LessonContent.comprehension(text)
            let review = LessonContent.reviewSummary(lesson, text)
            ComprehensionView(lesson: lesson, text: text, content: content, reviewContent: review)
            .safeAreaBar(edge: .bottom) {
                StageFooter(title: content.needsBook || review.needsBook
                                ? "Lu dans le livre, passer à la suite"
                                : nextTitle(after: .comprehension, plan: plan),
                            symbol: nextSymbol(after: .comprehension, plan: plan)) {
                    completeStage(.comprehension, plan: plan)
                }
            }
        }
    }

    @ViewBuilder
    private func translation(_ plan: DailyPlan) -> some View {
        if let number = plan.newLesson, let lesson = Manifest.shared.lesson(number) {
            let text = LessonTextStore.text(for: number)
            let items = LessonContent.translationItems(lesson, text)
            let numbers = items.map(\.n)
            RevealExerciseView(stage: .translation,
                               heading: "Exercice 1 · Traduisez",
                               instruction: "Traduis en français, au micro ou de tête.",
                               lesson: lesson,
                               items: items,
                               content: LessonContent.translation(lesson, text),
                               revealTitle: "Voir le corrigé",
                               promptFallback: "Énoncé écrit pas encore importé : écoute-le",
                               clipIsPrompt: true,
                               listener: frenchListener,
                               progress: progress,
                               oneAtATime: true)
            .safeAreaBar(edge: .bottom) {
                StageFooter(title: nextTitle(after: .translation, plan: plan),
                            symbol: nextSymbol(after: .translation, plan: plan),
                            enabled: session.progress.isDone(.translation, items: numbers),
                            hint: LessonContent.translation(lesson, text).needsBook
                                ? "Évalue chaque phrase, ou confirme l'exercice fait dans le livre."
                                : "Réponds à chaque phrase, au micro ou de tête.") {
                    completeStage(.translation, plan: plan, items: numbers)
                }
            }
        }
    }

    @ViewBuilder
    private func completion(_ plan: DailyPlan) -> some View {
        if let number = plan.newLesson, let lesson = Manifest.shared.lesson(number) {
            let text = LessonTextStore.text(for: number)
            let content = LessonContent.completion(lesson, text)
            let numbers = content == .available ? (text?.exercise2?.items.map(\.n) ?? []) : []
            FillInExerciseView(exercise: content == .available ? text?.exercise2 : nil,
                               content: content,
                               progress: progress) {
                StageFooter(title: nextTitle(after: .completion, plan: plan),
                            symbol: nextSymbol(after: .completion, plan: plan),
                            enabled: session.progress.isDone(.completion, items: numbers),
                            hint: content.needsBook
                                ? "Confirme l'exercice fait dans le livre pour continuer."
                                : "Réussis chaque phrase, ou affiche sa correction.") {
                    completeStage(.completion, plan: plan, items: numbers)
                }
            }
        }
    }

    @ViewBuilder
    private func secondWave(_ plan: DailyPlan) -> some View {
        if let number = plan.waveLesson, let lesson = Manifest.shared.lesson(number) {
            let text = LessonTextStore.text(for: number)
            let items = LessonContent.waveItems(lesson, text)
            let numbers = items.map(\.n)
            RevealExerciseView(stage: .secondWave,
                               heading: "Deuxième vague · leçon \(number)",
                               instruction: "Lis le français et dis la phrase en espagnol : au micro, l'app vérifie "
                                   + "qu'elle est identique ; de tête, affiche-la, écoute-la et évalue-toi.",
                               lesson: lesson,
                               items: items,
                               content: LessonContent.secondWave(lesson, text),
                               revealTitle: "Voir l'espagnol",
                               promptFallback: "Traduction pas encore importée",
                               clipIsPrompt: false,
                               listener: spanishListener,
                               progress: progress,
                               listenLesson: number)
            .safeAreaBar(edge: .bottom) {
                StageFooter(title: nextTitle(after: .secondWave, plan: plan),
                            symbol: nextSymbol(after: .secondWave, plan: plan),
                            enabled: session.progress.isDone(.secondWave, items: numbers),
                            hint: LessonContent.secondWave(lesson, text).needsBook
                                ? "Évalue chaque phrase, ou confirme la restitution faite dans le livre."
                                : "Réponds à chaque phrase, au micro ou de tête.") {
                    completeStage(.secondWave, plan: plan, items: numbers)
                }
            }
        }
    }

    private func nextTitle(after stage: DailyStage, plan: DailyPlan) -> String {
        guard let index = plan.stages.firstIndex(of: stage), index + 1 < plan.stages.count else {
            return "Continuer"
        }
        switch plan.stages[index + 1] {
        case .discovery: return "Passer à la découverte"
        case .comprehension: return "Passer à la compréhension"
        case .repetition: return "Passer à la répétition"
        case .translation: return "Passer aux exercices"
        case .completion: return "Passer à l'exercice 2"
        case .secondWave: return "Passer à la deuxième vague"
        case .finish: return validates(after: stage, plan: plan) ? "Valider la séance" : "Passer à la fin de séance"
        }
    }

    private func nextSymbol(after stage: DailyStage, plan: DailyPlan) -> String {
        validates(after: stage, plan: plan) ? "checkmark.seal" : "arrow.right"
    }

    /// Terminer cette étape validera la séance : c'est la dernière activité, et
    /// toutes les autres sont faites.
    private func validates(after stage: DailyStage, plan: DailyPlan) -> Bool {
        guard let index = plan.stages.firstIndex(of: stage), index + 1 < plan.stages.count,
              plan.stages[index + 1] == .finish
        else { return false }
        return plan.stages.filter { $0 != .finish && $0 != stage }.allSatisfy(session.progress.completed.contains)
    }

    /// Termine une étape. Si c'était la dernière et que tout est fait, la séance est
    /// validée du même geste et l'on revient à l'accueil, qui dit « terminée » et
    /// propose de retravailler la leçon demain : l'écran « Fin de séance » ne
    /// faisait que redire la liste des étapes avant un bouton.
    ///
    /// La validation reste un geste explicite : la fin d'une piste n'actionne rien.
    private func completeStage(_ stage: DailyStage, plan: DailyPlan, items: [Int] = []) {
        var updated = session.progress
        guard updated.complete(stage, in: plan.stages, items: items) else { return }
        progress.wrappedValue = updated
        if updated.current == .finish, store.validate(session, now: clock.now()) {
            dismiss()
        }
    }

    // MARK: - Fin de séance

    @ViewBuilder
    private func finish(_ plan: DailyPlan) -> some View {
        let progress = session.progress
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if session.isValidated {
                    validated(plan)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fin de séance").font(.title2.weight(.bold))
                        Text(summary(plan)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.stages.filter { $0 != .finish }) { stage in
                            let done = progress.completed.contains(stage)
                            Button {
                                self.progress.wrappedValue.open(stage, in: plan.stages)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(done ? StudyStyle.accent : .secondary)
                                    Text(stage.title)
                                    if progress.doneInBook.contains(stage) {
                                        Text("dans le livre").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!progress.isReachable(stage, in: plan.stages))
                        }
                    }
                    .studySection()

                    if progress.canValidate(plan.stages) {
                        Button {
                            store.validate(session, now: clock.now())
                        } label: {
                            Label("Valider la séance", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(StudyPrimaryButtonStyle())
                        .accessibilityIdentifier("validate-session")
                    } else {
                        Text("Il reste des étapes à faire avant de valider la séance.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func validated(_ plan: DailyPlan) -> some View {
        let tomorrow = tomorrowPlan()
        VStack(alignment: .leading, spacing: 8) {
            Label("Séance terminée pour aujourd'hui", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(StudyStyle.accent)
                .accessibilityIdentifier("session-done")
            Text(summary(plan)).font(.subheadline).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 14) {
            if let tomorrow {
                Text(TomorrowText.describe(tomorrow, after: plan))
                    .font(.headline)
            } else {
                Text("C'était la dernière séance du parcours.").font(.headline)
            }
            if isValidatedToday {
                Toggle("Retravailler cette leçon demain", isOn: Binding(
                    get: { session.repeatTomorrow },
                    set: { store.setRepeatTomorrow(session, $0) }))
                Text("En cas de difficulté, demain reprend la même séance au lieu de passer à la suivante.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .studySection()
        Button("Retour à l'accueil") { dismiss() }
            .buttonStyle(StudyPrimaryButtonStyle())
    }

    private var isValidatedToday: Bool {
        guard let completedAt = session.completedAt else { return false }
        return Calendar.current.isDate(completedAt, inSameDayAs: clock.today)
    }

    private func tomorrowPlan() -> DailyPlan? {
        let anchor = store.anchor()
        let next = DailyCourse.nextUnit(anchorUnit: anchor?.unit ?? session.unit,
                                        anchorSetAt: anchor?.setAt ?? .distantPast,
                                        sessions: store.sessions())
        return Curriculum.plan(unit: next)
    }

    private func summary(_ plan: DailyPlan) -> String {
        var parts: [String] = []
        if let lesson = plan.newLesson {
            parts.append(plan.isWeeklyReview ? "Révision de la leçon \(lesson)" : "Leçon \(lesson)")
        }
        if let wave = plan.waveLesson {
            parts.append("deuxième vague de la leçon \(wave)")
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

enum TomorrowText {
    static func describe(_ tomorrow: DailyPlan, after today: DailyPlan) -> String {
        if tomorrow.unit == today.unit {
            return "Demain : on retravaille la leçon \(today.headlineLesson)"
        }
        if let lesson = tomorrow.newLesson {
            let title = LessonTextStore.text(for: lesson)?.titleES
            return "Demain : leçon \(lesson)" + (title.map { " · \($0)" } ?? "")
        }
        return "Demain : deuxième vague de la leçon \(tomorrow.waveLesson ?? tomorrow.unit)"
    }
}

// MARK: - Briques communes

/// La suite des étapes, en tête de séance. On peut revenir sur une étape faite,
/// pas sauter au-delà de la première qui reste à faire.
struct StageFooter: View {
    let title: String
    var symbol = "arrow.right"
    var enabled = true
    var hint: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let hint, !enabled {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: action) {
                Label(title, systemImage: symbol)
            }
            .buttonStyle(StudyPrimaryButtonStyle())
            .disabled(!enabled)
            .accessibilityIdentifier("stage-footer")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// Ce qui manque, et qu'il faut aller chercher dans le livre.
struct BookNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "book")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("book-notice")
    }
}

/// La confirmation explicite qu'une activité a été faite dans le livre.
struct BookConfirmation: View {
    let stage: DailyStage
    let label: String
    @Binding var progress: DailyProgress

    var body: some View {
        if progress.doneInBook.contains(stage) {
            HStack {
                Label("Fait dans le livre", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(StudyStyle.accent)
                Spacer()
                Button("Annuler") { progress.doneInBook.remove(stage) }
                    .font(.subheadline)
            }
        } else {
            Button {
                progress.doneInBook.insert(stage)
            } label: {
                Label(label, systemImage: "book")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("done-in-book")
        }
    }
}

/// Lire le texte, les traductions et les notes — tout visible d'un coup, contrairement
/// au lecteur qui ne montre les notes que de la phrase en cours.
/// Le texte complet d'une leçon : l'étape Compréhension de la séance, et la page
/// d'une leçon dans l'onglet Leçons.
struct ComprehensionView: View {
    let lesson: Lesson
    let text: LessonText?
    let content: ActivityContent
    let reviewContent: ActivityContent

    @EnvironmentObject private var player: SessionPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lesson.isReview ? "Révision hebdomadaire · leçon \(lesson.number)" : "Leçon \(lesson.number)")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(text?.titleES ?? "Leçon \(lesson.number)")
                        .font(.title2.weight(.bold))
                    if let french = text?.titleFR {
                        Text(french).foregroundStyle(.secondary)
                    }
                }

                if lesson.isReview {
                    reviewSummary
                }

                if let notice = content.notice {
                    BookNotice(text: notice)
                }

                if lesson.isReview {
                    Text("Dialogue de révision").font(.headline).padding(.top, 4)
                }

                ForEach(lesson.dialogue, id: \.self) { clip in
                    sentence(clip)
                }
            }
            .padding(20)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synthèse de la semaine").font(.headline)
            if case .available = reviewContent, let sections = text?.review?.sections {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = section.title {
                            Text(title).font(.subheadline.weight(.semibold))
                        }
                        Text(section.text).font(.callout)
                    }
                }
            } else if let notice = reviewContent.notice {
                BookNotice(text: notice)
            }
        }
    }

    private func sentence(_ clip: AudioClip) -> some View {
        let n = clip.n ?? 0
        let line = text?.sentence(n)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(line?.es ?? "Phrase \(n)")
                    .font(.title3)
                    .foregroundStyle(line == nil ? .secondary : .primary)
                if let pron = line?.pron, !pron.isEmpty {
                    Text(pron).font(.caption).foregroundStyle(.secondary)
                }
                if let fr = line?.fr, !fr.isEmpty {
                    Text(fr).font(.callout).foregroundStyle(.secondary)
                }
                if let note = line?.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .padding(10)
                        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Spacer(minLength: 0)
            Button {
                player.start(.excerpt(lessonNumber: lesson.number),
                             steps: SessionBuilder.excerpt(clip, isExercise: false, in: lesson))
            } label: {
                Image(systemName: "speaker.wave.2").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyStyle.accent)
            .accessibilityLabel("Écouter la phrase \(n)")
        }
    }
}
