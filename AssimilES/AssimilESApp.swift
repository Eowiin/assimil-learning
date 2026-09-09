import SwiftUI
import SwiftData

@main
struct AssimilESApp: App {

    @StateObject private var player = SessionPlayer()
    @StateObject private var settings = AppSettings()
    @State private var nowPlaying: NowPlayingController?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(settings)
                .task {
                    player.rate = Float(settings.rate)
                    // Retenu au-delà de l'initialisation : c'est lui qui porte
                    // les cibles des commandes de l'écran verrouillé.
                    if nowPlaying == nil { nowPlaying = NowPlayingController(player: player) }
                }
        }
        .modelContainer(for: [LessonProgress.self, DifficultSentence.self, StudyDay.self])
    }
}
