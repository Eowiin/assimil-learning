import Foundation

enum StudyMode: String, CaseIterable, Identifiable {
    case passive
    case shadowing
    case reverse
    case wave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passive: "Écoute passive"
        case .shadowing: "Répétition"
        case .reverse: "Thème inversé"
        case .wave: "La vague"
        }
    }

    var subtitle: String {
        switch self {
        case .passive: "La leçon s'enchaîne, tu suis le texte"
        case .shadowing: "Une pause après chaque phrase pour répéter"
        case .reverse: "Le français d'abord, tu traduis, l'espagnol corrige"
        case .wave: "La leçon du jour, puis la révision active"
        }
    }

    var symbol: String {
        switch self {
        case .passive: "play.circle"
        case .shadowing: "repeat.circle"
        case .reverse: "arrow.left.arrow.right.circle"
        case .wave: "water.waves"
        }
    }

    /// Le thème inversé part du français : sans la traduction du livre, il n'a rien
    /// à énoncer. Les autres modes fonctionnent en audio seul — et l'espagnol
    /// transcrit depuis l'audio ne suffit donc pas à le rendre disponible.
    var requiresTranslation: Bool { self == .reverse }
}

/// Une étape de la séance. La séance entière est calculée d'avance, ce qui rend
/// la reprise, le saut de phrase et l'affichage de la progression triviaux.
struct SessionStep: Identifiable, Hashable {
    enum Kind: Hashable {
        case announcement
        case title
        case dialogue
        case exerciseIntro
        case exercise
        /// Silence pendant lequel Ethan répète. Joué comme du vrai audio (voir
        /// SessionPlayer) pour que l'app ne soit pas suspendue en arrière-plan.
        case pause
        /// Phrase française énoncée en synthèse vocale, faute d'audio français.
        case speakFrench(String)
    }

    let id = UUID()
    let kind: Kind
    let lessonNumber: Int
    let sentenceNumber: Int?
    let url: URL?
    let duration: Double

    var isPause: Bool { kind == .pause }

    /// Une étape sur laquelle il est pertinent de s'arrêter quand on saute de
    /// phrase en phrase — on ne « saute » pas vers un silence.
    var isNavigable: Bool {
        switch kind {
        case .pause: false
        default: true
        }
    }
}

struct SessionSettings {
    /// La pause vaut la durée de la phrase multipliée par ce facteur : une phrase
    /// longue mérite une pause longue. Une pause fixe serait trop courte pour les
    /// unes et interminable pour les autres.
    var pauseFactor: Double = 1.3
    var includeExercise: Bool = true
    var announceLesson: Bool = false
}

enum SessionBuilder {

    static func build(mode: StudyMode,
                      lesson: Lesson,
                      manifest: Manifest = .shared,
                      settings: SessionSettings = SessionSettings()) -> [SessionStep] {
        switch mode {
        case .passive: passive(lesson, manifest, settings)
        case .shadowing: shadowing(lesson, manifest, settings)
        case .reverse: reverse(lesson, manifest, settings)
        case .wave: wave(lesson, manifest, settings)
        }
    }

    // MARK: - Modes

    private static func passive(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep] {
        var steps = header(lesson, m, s)
        steps += lesson.dialogue.map { clip($0, .dialogue, lesson, m) }

        if s.includeExercise, !lesson.exercise.isEmpty {
            if let intro = lesson.exerciseIntro { steps.append(clip(intro, .exerciseIntro, lesson, m)) }
            steps += lesson.exercise.map { clip($0, .exercise, lesson, m) }
        }
        return steps.compactMap { $0 }
    }

    private static func shadowing(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep] {
        var steps = header(lesson, m, s)

        for c in lesson.dialogue {
            steps.append(clip(c, .dialogue, lesson, m))
            steps.append(pause(after: c, lesson: lesson, settings: s))
        }

        if s.includeExercise, !lesson.exercise.isEmpty {
            if let intro = lesson.exerciseIntro { steps.append(clip(intro, .exerciseIntro, lesson, m)) }
            for c in lesson.exercise {
                steps.append(clip(c, .exercise, lesson, m))
                steps.append(pause(after: c, lesson: lesson, settings: s))
            }
        }
        return steps.compactMap { $0 }
    }

    /// Français énoncé → silence pour traduire → phrase espagnole en correction.
    /// Les phrases sans traduction saisie sont sautées plutôt que jouées à moitié.
    private static func reverse(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep] {
        guard let text = LessonTextStore.text(for: lesson.number) else { return [] }
        var steps: [SessionStep?] = []

        for c in lesson.dialogue {
            guard let n = c.n, let french = text.sentence(n)?.fr, !french.isEmpty else { continue }
            steps.append(SessionStep(kind: .speakFrench(french),
                                     lessonNumber: lesson.number,
                                     sentenceNumber: n,
                                     url: nil,
                                     duration: estimatedSpeechDuration(french)))
            steps.append(pause(after: c, lesson: lesson, settings: s))
            steps.append(clip(c, .dialogue, lesson, m))
        }
        return steps.compactMap { $0 }
    }

    /// La vague Assimil : à partir de la leçon 50, chaque séance combine la leçon
    /// du jour en passif et la leçon d'il y a 49 jours en actif. C'est ce suivi
    /// manuel que l'app supprime.
    private static func wave(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep] {
        var steps = passive(lesson, m, s)
        if let active = activeLesson(for: lesson.number, in: m) {
            steps += shadowing(active, m, s)
        }
        return steps
    }

    /// Leçon à réviser activement en accompagnement de la leçon `number`.
    static func activeLesson(for number: Int, in m: Manifest = .shared) -> Lesson? {
        let target = number - 49
        guard target >= 1 else { return nil }
        return m.lesson(target)
    }

    // MARK: - Briques

    private static func header(_ lesson: Lesson, _ m: Manifest, _ s: SessionSettings) -> [SessionStep?] {
        var steps: [SessionStep?] = []
        if s.announceLesson, let a = lesson.announcement {
            steps.append(clip(a, .announcement, lesson, m))
        }
        if let t = lesson.title {
            steps.append(clip(t, .title, lesson, m))
        }
        return steps
    }

    private static func clip(_ c: AudioClip, _ kind: SessionStep.Kind,
                             _ lesson: Lesson, _ m: Manifest) -> SessionStep? {
        guard let url = m.url(for: c, in: lesson) else { return nil }
        return SessionStep(kind: kind,
                           lessonNumber: lesson.number,
                           sentenceNumber: c.n,
                           url: url,
                           duration: c.duration)
    }

    private static func pause(after c: AudioClip, lesson: Lesson, settings: SessionSettings) -> SessionStep {
        SessionStep(kind: .pause,
                    lessonNumber: lesson.number,
                    sentenceNumber: c.n,
                    url: nil,
                    duration: max(1.0, c.duration * settings.pauseFactor))
    }

    /// Estimation grossière, uniquement pour afficher une durée de séance
    /// plausible : la durée réelle est celle que met la synthèse vocale.
    private static func estimatedSpeechDuration(_ text: String) -> Double {
        max(1.5, Double(text.count) / 14.0)
    }
}
