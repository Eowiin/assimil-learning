import Foundation

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

struct Manifest: Decodable {
    let version: Int
    let lessonCount: Int
    let sentenceCount: Int
    let totalDuration: Double
    let lessons: [Lesson]

    static let shared: Manifest = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            // Le manifest est généré par tools/build-manifest.py et embarqué dans le
            // bundle : son absence est une erreur de build, pas un cas à gérer.
            fatalError("manifest.json introuvable ou illisible dans le bundle")
        }
        return manifest
    }()

    func lesson(_ number: Int) -> Lesson? {
        lessons.first { $0.number == number }
    }

    /// Emplacement d'un clip dans le bundle. Les fichiers sont rangés par leçon
    /// (`audio/L001/S01.m4a`) : les noms se répètent d'une leçon à l'autre, le
    /// sous-dossier est donc indispensable.
    func url(for clip: AudioClip, in lesson: Lesson) -> URL? {
        Bundle.main.url(
            forResource: (clip.file as NSString).deletingPathExtension,
            withExtension: "m4a",
            subdirectory: "audio/\(lesson.dir)"
        )
    }
}
