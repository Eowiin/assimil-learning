import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {

    @AppStorage("pauseFactor") var pauseFactor: Double = 1.3
    @AppStorage("rate") var rate: Double = 1.0
    @AppStorage("includeExercise") var includeExercise: Bool = true
    @AppStorage("announceLesson") var announceLesson: Bool = false
    @AppStorage("revealTranslation") var revealTranslation: Bool = false
    /// Leçon en cours dans la progression Assimil, pour la séance du jour.
    @AppStorage("currentLesson") var currentLesson: Int = 1

    var session: SessionSettings {
        SessionSettings(pauseFactor: pauseFactor,
                        includeExercise: includeExercise,
                        announceLesson: announceLesson)
    }
}
