import Foundation

/// Comment jouer une leçon hors de la séance du jour. L'onglet Leçons n'offre que
/// l'écoute ; la répétition sert à réécouter l'ancienne leçon de la deuxième vague.
/// Les valeurs brutes sont gardées dans `LessonProgress.mode` : ne pas les renommer.
enum StudyMode: String {
    case passive
    case shadowing

    var title: String {
        switch self {
        case .passive: "Écoute"
        case .shadowing: "Répétition"
        }
    }
}

/// Ce qu'on demande au lecteur de jouer.
///
/// C'est l'étape qui porte sa leçon, jamais la séance : la file de révision des
/// phrases, retirée depuis, en traversait plusieurs, et l'écran affichait alors le
/// texte d'une leçon pendant qu'on en entendait une autre. La règle reste.
enum SessionRequest: Hashable {
    case lesson(number: Int, mode: StudyMode)
    /// Une étape audio de la séance du jour. Elle n'enregistre aucune reprise dans
    /// `LessonProgress` : c'est la séance qui s'en souvient.
    case daily(lessonNumber: Int, audio: DailyAudio)
    /// Une phrase isolée, jouée depuis un exercice.
    case excerpt(lessonNumber: Int)

    var title: String {
        switch self {
        case .lesson(let number, _), .daily(let number, _), .excerpt(let number): "Leçon \(number)"
        }
    }

    var subtitle: String {
        switch self {
        case .lesson(_, let mode): mode.title
        case .daily(_, .discovery): "Découverte"
        case .daily(_, .repetition): "Répétition"
        case .excerpt: "Extrait"
        }
    }

    var isDaily: Bool {
        if case .daily = self { true } else { false }
    }

    /// Le mode, quand la séance en a un : seule l'écoute libre en a.
    var mode: StudyMode? {
        if case .lesson(_, let mode) = self { mode } else { nil }
    }

    /// À quoi compte le temps écouté par l'écran de lecture. Un extrait n'y est
    /// jamais joué : il se lance surtout depuis les exercices de la séance du jour,
    /// dont il prend l'activité.
    var studyActivity: StudyActivity {
        switch self {
        case .daily, .excerpt: .assimilDaily
        case .lesson: .assimilListen
        }
    }
}

enum DailyAudio: Hashable {
    /// Le dialogue d'un trait, sans pause ni exercice.
    case discovery
    /// Chaque phrase `times` fois, chacune suivie de sa pause.
    case repetition(times: Int)
}

/// Une étape de la séance. La séance entière est calculée d'avance, ce qui rend
/// la reprise, le saut de phrase et l'affichage de la progression triviaux.
struct SessionStep: Identifiable, Hashable {
    enum Kind: Hashable {
        case title
        case dialogue
        case exerciseIntro
        case exercise
        /// Silence pendant lequel Ethan répète. Joué comme du vrai audio (voir
        /// SessionPlayer) pour que l'app ne soit pas suspendue en arrière-plan.
        case pause
    }

    let id = UUID()
    let kind: Kind
    let lessonNumber: Int
    let sentenceNumber: Int?
    /// Vrai quand l'étape porte sur une phrase de l'exercice plutôt que du
    /// dialogue — **y compris pour la pause qui la suit**, dont le `kind` ne le
    /// dit plus. C'est ce qui distingue la phrase 3 de l'exercice de la phrase 3
    /// du dialogue, pour le texte affiché, la clé de carte et le nom de la prise
    /// de voix.
    let isExercise: Bool
    let url: URL?
    let duration: Double
    /// Rang de la répétition de cette phrase, à partir de 1. Les suivantes rejouent
    /// le même modèle et restent attachées à la première : une ligne à l'écran, et
    /// « phrase suivante » saute toutes les répétitions d'un coup.
    var repetition: Int = 1

    var isPause: Bool { kind == .pause }

    /// Une étape sur laquelle il est pertinent de s'arrêter quand on saute de
    /// phrase en phrase — on ne « saute » ni vers un silence, ni vers la deuxième
    /// répétition d'une phrase.
    var isNavigable: Bool {
        kind != .pause && repetition == 1
    }

    /// Même phrase de la même leçon, et du même côté (dialogue ou exercice) : le seul
    /// numéro ne suffit pas, la file de révision enchaîne des phrases 3 de leçons
    /// différentes.
    func isSameSentence(as other: SessionStep) -> Bool {
        sentenceNumber != nil
            && sentenceNumber == other.sentenceNumber
            && lessonNumber == other.lessonNumber
            && isExercise == other.isExercise
    }

    /// Le texte de cette étape quand il est saisi. Même résolution pour l'écran
    /// de lecture et pour l'écran verrouillé.
    var sentenceText: SentenceText? {
        guard let n = sentenceNumber, let text = LessonTextStore.text(for: lessonNumber) else { return nil }
        return isExercise ? text.exerciseSentence(n) : text.sentence(n)
    }

    /// La phrase Assimil de cette étape, s'il y en a une.
    var item: AssimilItem? {
        guard let n = sentenceNumber, lessonNumber > 0, n > 0 else { return nil }
        return AssimilItem(lesson: lessonNumber, isExercise: isExercise, number: n)
    }

    /// Le nom de la prise de voix de cette phrase : « L012-S04 », l'ancienne clé de
    /// phrase marquée. Les prises déjà enregistrées portent ce nom ; le garder évite
    /// d'avoir à renommer des fichiers pour suivre la clé des cartes.
    var recordingKey: String? {
        guard let n = sentenceNumber else { return nil }
        return String(format: "L%03d-%@%02d", lessonNumber, isExercise ? "T" : "S", n)
    }
}

struct SessionSettings {
    /// La pause vaut la durée de la phrase multipliée par ce facteur : une phrase
    /// longue mérite une pause longue. Une pause fixe serait trop courte pour les
    /// unes et interminable pour les autres.
    var pauseFactor: Double = 1.3
    /// L'écoute libre joue l'exercice à la suite du dialogue ; la séance du jour, non.
    var includeExercise: Bool = true
    /// Nombre de passages de chaque phrase en répétition.
    var repetitions: Int = 1
}

enum SessionBuilder {

    /// Point d'entrée unique : c'est la demande qui décide, et elle peut ne pas
    /// tenir dans une leçon.
    static func build(_ request: SessionRequest,
                      manifest: Manifest,
                      settings: SessionSettings = SessionSettings()) -> [SessionStep] {
        switch request {
        case .lesson(let number, let mode):
            guard let lesson = manifest.lesson(number) else { return [] }
            return build(mode: mode, lesson: lesson, manifest: manifest, settings: settings)
        case .daily(let number, let audio):
            guard let lesson = manifest.lesson(number) else { return [] }
            // Les exercices ne suivent jamais le dialogue dans la séance du jour :
            // on y passe par un geste, à l'écran des exercices.
            var daily = settings
            daily.includeExercise = false
            switch audio {
            case .discovery:
                return passive(lesson, manifest, daily)
            case .repetition(let times):
                daily.repetitions = max(1, times)
                return shadowing(lesson, manifest, daily)
            }
        case .excerpt:
            // Une phrase isolée se construit avec `excerpt(_:isExercise:in:)`.
            return []
        }
    }

    /// Une phrase seule, sans pause : l'audio d'un énoncé ou d'une réponse.
    static func excerpt(_ clip: AudioClip, isExercise: Bool, in lesson: Lesson,
                        manifest: Manifest) -> [SessionStep] {
        [self.clip(clip, isExercise ? .exercise : .dialogue, lesson, manifest)].compactMap { $0 }
    }

    /// Où reprendre dans une séance construite : la première étape de la phrase `n`
    /// du dialogue.
    static func index(ofSentence n: Int, in steps: [SessionStep]) -> Int? {
        steps.firstIndex { $0.isNavigable && !$0.isExercise && $0.sentenceNumber == n }
    }

    static func build(mode: StudyMode,
                      lesson: Lesson,
                      manifest: Manifest,
                      settings: SessionSettings = SessionSettings()) -> [SessionStep] {
        switch mode {
        case .passive: passive(lesson, manifest, settings)
        case .shadowing: shadowing(lesson, manifest, settings)
        }
    }

    // MARK: - Modes

    private static func passive(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep] {
        var steps = header(lesson, m)
        steps += lesson.dialogue.map { clip($0, .dialogue, lesson, m) }

        if s.includeExercise, !lesson.exercise.isEmpty {
            if let intro = lesson.exerciseIntro { steps.append(clip(intro, .exerciseIntro, lesson, m)) }
            steps += lesson.exercise.map { clip($0, .exercise, lesson, m) }
        }
        return steps.compactMap { $0 }
    }

    private static func shadowing(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep] {
        var steps = header(lesson, m)

        // Chaque passage rejoue le modèle puis laisse sa pause : on redit après
        // l'avoir réentendue, pas de mémoire.
        for c in lesson.dialogue {
            for repetition in 1...max(1, s.repetitions) {
                steps.append(clip(c, .dialogue, lesson, m, repetition: repetition))
                steps.append(pause(after: c, lesson: lesson, isExercise: false, settings: s,
                                   repetition: repetition))
            }
        }

        if s.includeExercise, !lesson.exercise.isEmpty {
            if let intro = lesson.exerciseIntro { steps.append(clip(intro, .exerciseIntro, lesson, m)) }
            for c in lesson.exercise {
                steps.append(clip(c, .exercise, lesson, m))
                steps.append(pause(after: c, lesson: lesson, isExercise: true, settings: s))
            }
        }
        return steps.compactMap { $0 }
    }

    // MARK: - Briques

    private static func header(_ lesson: Lesson, _ m: Manifest) -> [SessionStep?] {
        var steps: [SessionStep?] = []
        if let t = lesson.title {
            steps.append(clip(t, .title, lesson, m))
        }
        return steps
    }

    private static func clip(_ c: AudioClip, _ kind: SessionStep.Kind,
                             _ lesson: Lesson, _ m: Manifest, repetition: Int = 1) -> SessionStep? {
        guard let url = m.url(for: c, in: lesson) else { return nil }
        return SessionStep(kind: kind,
                           lessonNumber: lesson.number,
                           sentenceNumber: c.n,
                           isExercise: kind == .exercise || kind == .exerciseIntro,
                           url: url,
                           duration: c.duration,
                           repetition: repetition)
    }

    /// Le clip d'une phrase Assimil : celui que joue le verso d'une carte de mot.
    static func clip(for item: AssimilItem, in lesson: Lesson) -> AudioClip? {
        let clips = item.isExercise ? lesson.exercise : lesson.dialogue
        return clips.first { $0.n == item.number }
    }

    private static func pause(after c: AudioClip, lesson: Lesson,
                              isExercise: Bool, settings: SessionSettings,
                              repetition: Int = 1) -> SessionStep {
        SessionStep(kind: .pause,
                    lessonNumber: lesson.number,
                    sentenceNumber: c.n,
                    isExercise: isExercise,
                    url: nil,
                    duration: max(1.0, c.duration * settings.pauseFactor),
                    repetition: repetition)
    }
}
