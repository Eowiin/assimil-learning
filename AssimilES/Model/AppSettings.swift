import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {

    @AppStorage("pauseFactor") var pauseFactor: Double = 1.3
    @AppStorage("rate") var rate: Double = 1.0
    @AppStorage("revealTranslation") var revealTranslation: Bool = false
    /// Ancien réglage manuel de la leçon en cours. Il ne sert plus qu'une fois : à
    /// placer le point de départ du parcours au premier lancement de la version qui
    /// le suit (`DailyCourseStore.ensureAnchor`).
    @AppStorage("currentLesson") var currentLesson: Int = 1
    /// Répétitions de chaque phrase à l'étape Répétition de la séance du jour. Un
    /// repère pratique, réglable — pas une règle Assimil.
    @AppStorage("repetitionsPerSentence") var repetitionsPerSentence: Int = 3
    /// L'adresse du PC de la maison dans Tailscale (`HomeServer`). Vide : pas de serveur.
    @AppStorage("serverAddress") var serverAddress: String = ""

    var session: SessionSettings {
        SessionSettings(pauseFactor: pauseFactor)
    }
}
