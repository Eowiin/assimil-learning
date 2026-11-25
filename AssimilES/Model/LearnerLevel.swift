import Foundation
import SwiftData

/// Le niveau de l'apprenant (`docs/moteur-adaptatif.md`, étape 5b) : celui de son objectif
/// actif, sinon celui du dernier placement validé.
///
/// Depuis la 5a, un cycle peut reprendre un objectif d'un niveau plus bas. L'IA, le texte
/// du bloc 2, les amorces et la longueur de l'écrit se règlent sur l'apprenant, pas sur
/// l'objectif repris : un apprenant B1 qui revoit un point A1 ne redevient pas débutant.
@MainActor
enum LearnerLevel {

    static func current(pack: CurriculumPack, in context: ModelContext) -> String? {
        let language = pack.language
        let active = ObjectiveProgress.Status.active
        let progresses = (try? context.fetch(FetchDescriptor<ObjectiveProgress>(
            predicate: #Predicate { $0.status == active }))) ?? []
        let ids = Set(progresses.filter { $0.language == language }.map(\.objectiveID))
        // Dans l'ordre du parcours : s'il y en avait deux, le premier.
        if let objective = pack.objectives.first(where: { ids.contains($0.id) }) { return objective.level }
        return PlacementStore.latestCompleted(language: language, in: context)?.level
    }

    /// A0 et A1 : les amorces sous chaque réplique, la voix ralentie, un écrit très court.
    nonisolated static func isBeginner(_ level: String?) -> Bool {
        level == "A0" || level == "A1"
    }

    /// La vitesse de la voix de l'IA en conversation : ralentie pour un débutant, sans
    /// changer la hauteur.
    nonisolated static func playbackRate(_ level: String?) -> Float {
        isBeginner(level) ? 0.85 : 1
    }
}
