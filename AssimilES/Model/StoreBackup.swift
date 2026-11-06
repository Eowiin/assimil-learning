import Foundation
import SwiftData

/// Copie du stockage SwiftData, à mettre à l'abri dans Fichiers avant toute
/// migration de schéma. C'est un filet de sécurité, pas une fonction d'usage :
/// la restauration se fait à la main (voir le README).
///
/// SQLite tient le stockage en trois fichiers. Les écritures récentes vivent dans
/// `-wal` tant qu'elles n'ont pas été reportées dans le fichier principal : copier
/// `.store` seul pourrait perdre les derniers jours. On copie donc les trois
/// ensemble, juste après avoir sauvegardé le contexte, sans écriture entre-temps.
enum StoreBackup {
    static let suffixes = ["", "-wal", "-shm"]

    /// Sauvegarde le contexte puis copie le stockage dans un dossier daté, créé
    /// sous `directory`. Le dossier est rendu tel quel : c'est lui qu'on exporte.
    @MainActor
    static func make(from context: ModelContext,
                     into directory: URL = FileManager.default.temporaryDirectory,
                     now: Date = .now) throws -> URL {
        try context.save()
        guard let storeURL = context.container.configurations.first?.url else {
            throw BackupError.noStore
        }
        return try copy(storeURL: storeURL, into: directory, now: now)
    }

    static func copy(storeURL: URL, into directory: URL, now: Date = .now) throws -> URL {
        let fm = FileManager.default
        // Un stockage en mémoire répond `/dev/null`, qui existe bel et bien.
        guard storeURL.path != "/dev/null", fm.fileExists(atPath: storeURL.path) else {
            throw BackupError.noStore
        }

        let folder = directory.appendingPathComponent(folderName(at: now), isDirectory: true)
        // Deux exports dans la même minute : le second remplace le premier, resté
        // dans le dossier temporaire, plutôt que d'échouer.
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        for suffix in suffixes {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            // `-wal` et `-shm` peuvent manquer, après un point de contrôle complet.
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        }
        return folder
    }

    /// « AssimilES-sauvegarde-2026-11-06-1530 » : se trie par date dans Fichiers.
    static func folderName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "AssimilES-sauvegarde-\(formatter.string(from: date))"
    }

    enum BackupError: LocalizedError {
        case noStore

        var errorDescription: String? {
            "Le fichier du stockage est introuvable : il n'y a rien à exporter."
        }
    }
}
