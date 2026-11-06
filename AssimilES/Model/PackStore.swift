import Foundation
import Observation

/// Un paquet de contenu : tout ce qui vient du livre et de l'audio, jamais
/// l'état de l'apprenant (qui vit dans SwiftData).
///
/// Disposition, la même dans `Application Support/Packs/<id>/` et dans le bundle :
///
/// ```
/// manifest.json
/// audio/L001/S01.m4a …
/// text/L001.json …
/// ```
///
/// C'est ce qui permet au bundle de servir de paquet pendant la transition, sans
/// rien déplacer.
struct ContentPack {
    enum Source: String {
        /// Copié dans `Application Support/Packs/` — à terme, importé depuis Fichiers.
        case installed
        /// Embarqué dans l'app, comme jusqu'ici.
        case bundle
    }

    let id: String
    let root: URL
    let source: Source
    let manifest: Manifest

    var textDirectory: URL { root.appendingPathComponent("text", isDirectory: true) }
}

/// Trouve les paquets de contenu. Remplace `Manifest.shared`, qui plantait l'app
/// au lancement quand le manifest manquait : un paquet absent est un état
/// normal — l'app l'affiche, elle ne s'arrête pas.
///
/// `@Observable` sans rien qui change encore : l'import d'un paquet depuis Fichiers
/// le fera évoluer en cours d'usage, et les vues suivront.
@MainActor
@Observable
final class PackStore {
    /// Le seul cours pour l'instant. L'identifiant ne porte pas de version : il
    /// entre dans les identifiants d'items (`ItemID`) que SwiftData garde.
    nonisolated static let assimilSpanishID = "assimil-es"

    private(set) var assimil: ContentPack?

    init(installedRoot: URL? = PackStore.installedRoot,
         bundleRoot: URL? = Bundle.main.resourceURL) {
        assimil = Self.load(id: Self.assimilSpanishID, installedRoot: installedRoot, bundleRoot: bundleRoot)
    }

    /// `Application Support/Packs/`. Pas dans `Documents` : ce n'est pas un
    /// fichier de l'utilisateur, et il n'a pas à apparaître dans Fichiers.
    nonisolated static var installedRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Packs", isDirectory: true)
    }

    /// Le paquet installé d'abord, le bundle ensuite. Un manifest présent mais
    /// illisible fait passer au suivant plutôt que d'échouer.
    nonisolated static func load(id: String, installedRoot: URL?, bundleRoot: URL?) -> ContentPack? {
        let candidates: [(URL?, ContentPack.Source)] = [
            (installedRoot?.appendingPathComponent(id, isDirectory: true), .installed),
            // Le bundle n'a qu'un paquet, posé à sa racine.
            (id == assimilSpanishID ? bundleRoot : nil, .bundle),
        ]
        for case let (root?, source) in candidates {
            if let manifest = readManifest(in: root) {
                return ContentPack(id: id, root: root, source: source, manifest: manifest)
            }
        }
        return nil
    }

    nonisolated private static func readManifest(in root: URL) -> Manifest? {
        let url = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              var manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        manifest.audioRoot = root.appendingPathComponent("audio", isDirectory: true)
        manifest.checksAudioFiles = true
        return manifest
    }
}
