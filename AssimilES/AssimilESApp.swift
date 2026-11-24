import SwiftUI
import SwiftData

@main
struct AssimilESApp: App {

    @StateObject private var player = SessionPlayer()
    @StateObject private var settings = AppSettings()
    @StateObject private var clock = DayClock()
    @State private var nowPlaying: NowPlayingController?
    @State private var packs: PackStore
    @State private var server = AppEnvironment.fakeServer ? ServerStatus.fakeOnline() : ServerStatus()
    /// Le texte du bloc 2 et sa voix, préparés en tâche de fond d'un écran à l'autre.
    @State private var absorption = AbsorptionPreparer()
    /// La voix des phrases du bloc 1, gardée sur le disque (étape 5c).
    @State private var voices = VoicePreparer()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let packs = PackStore()
        _packs = State(initialValue: packs)
        // Les textes suivent le paquet trouvé. En Debug, `ASSIMIL_TEXT_DIR` garde
        // la main pour les tests d'interface.
        LessonTextStore.directory = AppEnvironment.textDirectory ?? packs.assimil?.textDirectory
        // Avant toute vue : la dernière copie de l'ancien modèle, une seule fois.
        // Ensuite, la révision et le temps d'étude ne vivent plus que dans les cartes.
        LegacyCopy.finishIfNeeded(in: container.mainContext)
        // La révision des phrases marquées est retirée : leurs cartes sont
        // désactivées (pas supprimées), une fois. Après la copie, qui en crée.
        CardReview.retireListenCards(in: container.mainContext)
        // Les mots déjà travaillés en révision Assimil entrent dans le lexique adaptatif,
        // une fois. Après la copie et le retrait, qui touchent aux cartes.
        LexiconMigration.finishIfNeeded(ranks: { CurriculumPack.bundled()?.ranks ?? [:] },
                                        in: container.mainContext)
        // La voix des phrases du bloc 1 d'une voix d'avant ne se rejoue plus (étape 5c).
        VoiceCache.purgeOtherVersions()
    }

    /// Chaque entité ajoutée (`DailySession`, `CourseAnchor`, puis `Card`,
    /// `ReviewLog`, `StudyEvent`, `DataMigration`, puis `ConversationRecord`, puis
    /// `PronunciationRecord`, puis les six du moteur adaptatif) est une
    /// migration légère : les entités existantes ne changent pas, SwiftData ajoute
    /// les tables.
    private let container = AssimilESApp.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(clock)
                .environment(packs)
                .environment(server)
                .environment(absorption)
                .environment(voices)
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
            if scenePhase == .active {
                clock.refresh()
                // Le PC a pu s'allumer ou s'éteindre pendant que l'app dormait.
                Task { await server.check(address: settings.serverAddress) }
            }
            if scenePhase == .background { try? container.mainContext.save() }
        }
    }

    nonisolated static let models: [any PersistentModel.Type] = [
        LessonProgress.self, DifficultSentence.self, StudyDay.self, DailySession.self, CourseAnchor.self,
        Card.self, ReviewLog.self, StudyEvent.self, DataMigration.self, ConversationRecord.self,
        PronunciationRecord.self,
        // Le moteur adaptatif.
        ObjectiveProgress.self, ObjectiveEvidence.self, LexemeState.self, PlacementResult.self,
        StudySession.self, WritingRecord.self,
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
