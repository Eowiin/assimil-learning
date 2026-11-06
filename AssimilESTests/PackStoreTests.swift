import Foundation
import Testing
@testable import AssimilES

@Suite("Paquets de contenu")
@MainActor
struct PackStoreTests {

    /// Un paquet fictif sur disque : le manifest de `Fixture`, et un seul clip.
    @discardableResult
    private func makePack(in root: URL, id: String = PackStore.assimilSpanishID, lessonCount: Int = 3) throws -> URL {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio/L001"), withIntermediateDirectories: true)
        let lessons = (1...lessonCount).map { n in
            """
            {"number": \(n), "isReview": false, "dir": "L\(String(format: "%03d", n))",
             "dialogue": [{"file": "S01.m4a", "duration": 2.0, "n": 1}], "exercise": []}
            """
        }
        let json = """
            {"version": 1, "lessonCount": \(lessonCount), "sentenceCount": \(lessonCount),
             "totalDuration": 6.0, "lessons": [\(lessons.joined(separator: ","))]}
            """
        try Data(json.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        try Data().write(to: dir.appendingPathComponent("audio/L001/S01.m4a"))
        return dir
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Un paquet installé passe avant celui du bundle")
    func installedFirst() throws {
        let installed = temporaryRoot()
        let bundle = temporaryRoot()
        try makePack(in: installed, lessonCount: 3)
        // Le bundle porte son paquet à la racine.
        let bundleRoot = try makePack(in: bundle, lessonCount: 5)

        let pack = try #require(PackStore.load(id: PackStore.assimilSpanishID, installedRoot: installed, bundleRoot: bundleRoot))
        #expect(pack.source == .installed)
        #expect(pack.manifest.lessonCount == 3)
        #expect(pack.textDirectory.lastPathComponent == "text")
    }

    @Test("Sans paquet installé, le bundle sert de paquet")
    func bundleFallback() throws {
        let bundleRoot = try makePack(in: temporaryRoot(), lessonCount: 5)
        let pack = try #require(PackStore.load(id: PackStore.assimilSpanishID, installedRoot: temporaryRoot(), bundleRoot: bundleRoot))
        #expect(pack.source == .bundle)
        #expect(pack.manifest.lessonCount == 5)
    }

    @Test("Aucun paquet : pas de plantage, un magasin vide")
    func nothingFound() {
        let store = PackStore(installedRoot: temporaryRoot(), bundleRoot: temporaryRoot())
        #expect(store.assimil == nil)
    }

    @Test("Un manifest illisible fait passer au paquet suivant")
    func unreadableSkipped() throws {
        let installed = temporaryRoot()
        let broken = installed.appendingPathComponent(PackStore.assimilSpanishID, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("pas du json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        let bundleRoot = try makePack(in: temporaryRoot())

        let pack = try #require(PackStore.load(id: PackStore.assimilSpanishID, installedRoot: installed, bundleRoot: bundleRoot))
        #expect(pack.source == .bundle)
    }

    @Test("L'audio se cherche dans le paquet ; un clip absent est sauté")
    func audioFromPack() throws {
        let root = try makePack(in: temporaryRoot())
        let pack = try #require(PackStore.load(id: PackStore.assimilSpanishID, installedRoot: nil, bundleRoot: root))
        let manifest = pack.manifest
        let present = try #require(manifest.lesson(1))
        let missing = try #require(manifest.lesson(2))

        let url = try #require(manifest.url(for: present.dialogue[0], in: present))
        #expect(url.path.hasSuffix("audio/L001/S01.m4a"))
        #expect(manifest.url(for: missing.dialogue[0], in: missing) == nil)
        #expect(SessionBuilder.build(.lesson(number: 2, mode: .passive), manifest: manifest).isEmpty)
    }

    @Test("Un autre cours ne se cherche pas dans le bundle")
    func bundleIsAssimilOnly() throws {
        let bundleRoot = try makePack(in: temporaryRoot(), id: PackStore.assimilSpanishID)
        #expect(PackStore.load(id: "autre-cours", installedRoot: nil, bundleRoot: bundleRoot) == nil)
    }
}

@Suite("Identifiants d'items")
struct ItemIDTests {

    @Test("Construction : leçon sur trois chiffres, phrase sur deux")
    func build() {
        #expect(AssimilItem(lesson: 12, isExercise: false, number: 4).itemID().rawValue == "assimil-es:L012:S04")
        #expect(AssimilItem(lesson: 12, isExercise: true, number: 3).itemID().rawValue == "assimil-es:L012:T03")
        #expect(AssimilItem(lesson: 100, isExercise: false, number: 21).itemID().rawValue == "assimil-es:L100:S21")
    }

    @Test("Aller-retour : analyser puis réécrire redonne l'original")
    func roundTrip() throws {
        for raw in ["assimil-es:L001:S01", "assimil-es:L012:T03", "assimil-es:L100:S21"] {
            let id = try #require(ItemID(raw))
            #expect(id.pack == "assimil-es")
            let item = try #require(AssimilItem(id))
            #expect(item.itemID().rawValue == raw)
        }
        let item = try #require(ItemID("assimil-es:L012:T03").flatMap(AssimilItem.init))
        #expect(item == AssimilItem(lesson: 12, isExercise: true, number: 3))
    }

    @Test("Seule la forme canonique est acceptée", arguments: [
        "assimil-es:L12:S04",    // leçon sans zéros
        "assimil-es:L012:S4",    // phrase sans zéro
        "assimil-es:L012:X04",   // ni dialogue ni exercice
        "assimil-es:L012-S04",   // ancienne clé
        "assimil-es:L000:S01",   // pas de leçon zéro
        "assimil-es:L012:S00",   // le titre n'est pas une phrase
        "assimil-es:L+12:S04",
        "assimil-es:L012:S04:x",
    ])
    func rejectsNonCanonical(_ raw: String) {
        #expect(ItemID(raw).flatMap(AssimilItem.init) == nil)
    }

    @Test("Le paquet : minuscules, chiffres, tirets, et non vide", arguments: [
        "", ":L012:S04", "Assimil-ES:L012:S04", "assimil es:L012:S04", "assimil-es:", "assimil-es",
    ])
    func rejectsBadPack(_ raw: String) {
        #expect(ItemID(raw) == nil)
    }

    @Test("Le chemin appartient au paquet : un autre cours n'est pas lu comme Assimil")
    func opaquePath() throws {
        let id = try #require(ItemID("conjugaison-es:ser:presente:1s"))
        #expect(id.pack == "conjugaison-es")
        #expect(id.path == "ser:presente:1s")
        #expect(AssimilItem(id) == nil)
    }

    @Test("Ancienne clé de phrase marquée → identifiant global")
    func legacyKey() throws {
        #expect(AssimilItem(legacyKey: "L012-S04")?.itemID().rawValue == "assimil-es:L012:S04")
        #expect(AssimilItem(legacyKey: "L012-T03")?.itemID().rawValue == "assimil-es:L012:T03")
        let key = DifficultSentence.makeKey(7, 11, true)
        #expect(AssimilItem(legacyKey: key) == AssimilItem(lesson: 7, isExercise: true, number: 11))
        #expect(AssimilItem(legacyKey: "n'importe quoi") == nil)
    }

    @Test("L'ordre des identifiants suit l'ordre du livre")
    func ordering() {
        let ids = [(100, false, 1), (9, false, 12), (9, false, 3), (9, true, 1)]
            .map { AssimilItem(lesson: $0.0, isExercise: $0.1, number: $0.2).itemID() }
        #expect(ids.sorted().map(\.path) == ["L009:S03", "L009:S12", "L009:T01", "L100:S01"])
    }
}
