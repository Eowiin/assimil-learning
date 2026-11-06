import SwiftUI
import SwiftData

@main
struct AssimilESApp: App {

    @StateObject private var player = SessionPlayer()
    @StateObject private var settings = AppSettings()
    @StateObject private var clock = DayClock()
    @State private var nowPlaying: NowPlayingController?
    @State private var packs: PackStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let packs = PackStore()
        _packs = State(initialValue: packs)
        // Les textes suivent le paquet trouvé. En Debug, `ASSIMIL_TEXT_DIR` garde
        // la main pour les tests d'interface.
        LessonTextStore.directory = AppEnvironment.textDirectory ?? packs.assimil?.textDirectory
    }

    /// Ajouter `DailySession` et `CourseAnchor` est une migration légère : les
    /// entités existantes ne changent pas, SwiftData ajoute les tables.
    private let container = AssimilESApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(clock)
                .environment(packs)
                .task {
                    player.rate = Float(settings.rate)
                    // Retenu au-delà de l'initialisation : c'est lui qui porte
                    // les cibles des commandes de l'écran verrouillé.
                    if nowPlaying == nil { nowPlaying = NowPlayingController(player: player) }
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) {
            AudioLog.info("scène : \(String(describing: scenePhase))")
            if scenePhase == .active { clock.refresh() }
            if scenePhase == .background { try? container.mainContext.save() }
        }
    }

    nonisolated static let models: [any PersistentModel.Type] = [
        LessonProgress.self, DifficultSentence.self, StudyDay.self, DailySession.self, CourseAnchor.self,
    ]

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        let configuration = AppEnvironment.storeURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("stockage indisponible : \(error)")
        }
    }
}
