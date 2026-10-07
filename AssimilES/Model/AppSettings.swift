import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {

    @AppStorage("pauseFactor") var pauseFactor: Double = 1.3
    @AppStorage("rate") var rate: Double = 1.0
    @AppStorage("includeExercise") var includeExercise: Bool = true
    @AppStorage("announceLesson") var announceLesson: Bool = false
    @AppStorage("revealTranslation") var revealTranslation: Bool = false
    /// Ancien réglage manuel de la leçon en cours. Il ne sert plus qu'une fois : à
    /// placer le point de départ du parcours au premier lancement de la version qui
    /// le suit (`DailyCourseStore.ensureAnchor`).
    @AppStorage("currentLesson") var currentLesson: Int = 1
    /// Répétitions de chaque phrase à l'étape Répétition de la séance du jour. Un
    /// repère pratique, réglable — pas une règle Assimil.
    @AppStorage("repetitionsPerSentence") var repetitionsPerSentence: Int = 3
    /// Le mode d'écoute libre choisi dans Leçons, gardé d'une fois sur l'autre.
    @AppStorage("freeListeningMode") private var freeListeningModeRaw = StudyMode.shadowing.rawValue

    var freeListeningMode: StudyMode {
        get { StudyMode(rawValue: freeListeningModeRaw) ?? .shadowing }
        set { freeListeningModeRaw = newValue.rawValue }
    }

    /// Réglages de l'écoute libre : une pause par phrase, comme avant le parcours,
    /// pour que les reprises enregistrées gardent leur sens.
    var session: SessionSettings {
        SessionSettings(pauseFactor: pauseFactor,
                        includeExercise: includeExercise,
                        announceLesson: announceLesson)
    }
}
