import CryptoKit
import Foundation
import Observation

// La voix des phrases du bloc 1 (`docs/moteur-adaptatif.md`, étape 5c) : la phrase
// d'une carte du lexique et les exemples de la micro-leçon. Demandée une fois à
// `POST /tts`, gardée pour toujours : une phrase ne change pas, et c'est ce qui rend
// la voix en ligne (Voxtral) presque gratuite à la longue.

/// Un .m4a par phrase, dans `Application Support/voix/<version>/`, nommé d'après la
/// phrase.
enum VoiceCache {
    /// La voix du serveur dont le cache est fait. À changer quand elle change (une autre
    /// voix, une autre vitesse) : le cache d'avant part, et les phrases se redemandent.
    static let version = "voxtral-elena-0.9"

    static var base: URL {
        URL.applicationSupportDirectory.appending(path: "voix", directoryHint: .isDirectory)
    }

    static var defaultRoot: URL { base.appending(path: version, directoryHint: .isDirectory) }

    /// Retire de `base` ce qui n'est pas la version en cours : les dossiers d'une voix
    /// d'avant, et les fichiers rangés à plat par la première version.
    static func purgeOtherVersions(base: URL = base, keeping version: String = version) {
        let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != version {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// La phrase telle qu'on la range : sans espaces en trop. La casse et la
    /// ponctuation comptent : « ¿Qué? » ne se dit pas comme « qué ».
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func url(for text: String, root: URL = defaultRoot) -> URL {
        let digest = SHA256.hash(data: Data(normalized(text).utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(name).m4a")
    }

    /// Le fichier de la phrase, s'il est là et pas vide.
    static func cached(_ text: String, root: URL = defaultRoot) -> URL? {
        let url = url(for: text, root: root)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0 ? url : nil
    }

    /// Range la voix d'une phrase. Un audio vide (le faux serveur des tests
    /// d'interface) n'est pas gardé.
    static func write(_ data: Data, for text: String, root: URL = defaultRoot) throws {
        guard !data.isEmpty, !normalized(text).isEmpty else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url(for: text, root: root), options: .atomic)
    }

    /// Les phrases sans voix, sans doublon, dans l'ordre.
    static func missing(_ texts: [String], root: URL = defaultRoot) -> [String] {
        var seen = Set<String>()
        return texts.map(normalized).filter { !$0.isEmpty && seen.insert($0).inserted && cached($0, root: root) == nil }
    }

    /// Ce que le bloc 1 peut faire entendre : les exemples de la micro-leçon d'abord (ils
    /// servent dans le cycle), puis la phrase de chaque mot du lexique, la plus récente
    /// en premier. Chaque phrase n'est demandée qu'une fois : la liste fond à mesure.
    static func blockOneTexts(microlesson: CurriculumPack.MicroLesson?, lexicon: LexiconWords) -> [String] {
        (microlesson?.examples.map(\.es) ?? []) + lexicon.words.reversed().map(\.sentence)
    }
}

/// Prépare la voix des phrases du bloc 1 en tâche de fond, par paquets de 5, et en
/// demande une à la volée quand on la veut avant qu'elle soit prête.
@Observable
@MainActor
final class VoicePreparer {
    /// Ce qui a changé sur le disque : les boutons relisent le cache quand il bouge.
    private(set) var version = 0
    /// Les phrases en cours de demande, une par une.
    private(set) var fetching: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let root: URL

    init(root: URL = VoiceCache.defaultRoot) {
        self.root = root
    }

    var isRunning: Bool { task != nil }

    func url(for text: String) -> URL? {
        _ = version
        return VoiceCache.cached(text, root: root)
    }

    func isFetching(_ text: String) -> Bool { fetching.contains(VoiceCache.normalized(text)) }

    /// Demande la voix des phrases qui n'en ont pas. Sans effet si une préparation
    /// tourne déjà ; un paquet raté arrête la préparation (le PC s'est éteint), la
    /// suivante reprendra où elle en était.
    func prepare(_ texts: [String], service: any AbsorptionService) {
        guard task == nil else { return }
        let missing = VoiceCache.missing(texts, root: root)
        guard !missing.isEmpty else { return }
        task = Task { [weak self] in
            for start in stride(from: 0, to: missing.count, by: Absorption.voiceBatch) {
                let batch = Array(missing[start..<min(start + Absorption.voiceBatch, missing.count)])
                guard let audios = try? await service.speak(batch) else { break }
                self?.store(audios, for: batch)
            }
            self?.task = nil
        }
    }

    /// La voix d'une phrase tout de suite : celle du cache, sinon demandée seule.
    func fetch(_ text: String, service: any AbsorptionService) async -> URL? {
        if let url = url(for: text) { return url }
        let key = VoiceCache.normalized(text)
        guard !fetching.contains(key) else { return nil }
        fetching.insert(key)
        defer { fetching.remove(key) }
        guard let audios = try? await service.speak([key]) else { return nil }
        store(audios, for: [key])
        return url(for: key)
    }

    private func store(_ audios: [Data], for texts: [String]) {
        for (text, audio) in zip(texts, audios) {
            try? VoiceCache.write(audio, for: text, root: root)
        }
        version += 1
    }
}
