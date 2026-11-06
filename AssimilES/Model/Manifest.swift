import Foundation
import SwiftUI

/// Un fichier audio : une phrase, un titre ou une annonce.
struct AudioClip: Decodable, Hashable {
    let file: String
    let duration: Double
    /// Numéro de la phrase dans le dialogue ou l'exercice. Absent pour les titres.
    let n: Int?
}

struct Lesson: Decodable, Identifiable, Hashable {
    let number: Int
    /// Les 14 leçons de révision n'ont pas d'exercice — ce n'est pas une donnée manquante.
    let isReview: Bool
    let dir: String
    let announcement: AudioClip?
    let title: AudioClip?
    let dialogue: [AudioClip]
    let exerciseIntro: AudioClip?
    let exercise: [AudioClip]

    var id: Int { number }

    /// Durée cumulée du dialogue, telle qu'affichée dans la liste des leçons.
    var dialogueDuration: Double { dialogue.reduce(0) { $0 + $1.duration } }
}

/// L'index d'un paquet Assimil : les leçons et leurs clips. Il ne sait pas d'où il
/// vient — c'est `PackStore` qui le trouve et lui dit où est l'audio.
struct Manifest: Decodable {
    let version: Int
    let lessonCount: Int
    let sentenceCount: Int
    let totalDuration: Double
    let lessons: [Lesson]
    /// Dossier `audio/` du paquet. Les fichiers y sont rangés par leçon
    /// (`audio/L001/S01.m4a`) : les noms se répètent d'une leçon à l'autre, le
    /// sous-dossier est donc indispensable.
    var audioRoot: URL? = nil
    /// Vérifier que le fichier existe avant de le proposer. Vrai pour un vrai
    /// paquet : un clip absent est sauté, comme le faisait la recherche dans le
    /// bundle. Faux pour les tests, dont l'audio est fictif.
    var checksAudioFiles = false

    private enum CodingKeys: String, CodingKey {
        case version, lessonCount, sentenceCount, totalDuration, lessons
    }

    /// Aucun paquet : zéro leçon. Sert de valeur par défaut à l'environnement, que
    /// l'accueil ne laisse jamais atteindre (il affiche l'état vide à la place).
    static let empty = Manifest(version: 0, lessonCount: 0, sentenceCount: 0, totalDuration: 0, lessons: [])

    func lesson(_ number: Int) -> Lesson? {
        lessons.first { $0.number == number }
    }

    func url(for clip: AudioClip, in lesson: Lesson) -> URL? {
        guard let audioRoot else { return nil }
        let url = audioRoot.appendingPathComponent(lesson.dir).appendingPathComponent(clip.file)
        if checksAudioFiles, !FileManager.default.fileExists(atPath: url.path) { return nil }
        return url
    }
}

extension EnvironmentValues {
    /// Le manifest du paquet Assimil, posé par l'accueil une fois le paquet trouvé.
    @Entry var manifest: Manifest = .empty
}
