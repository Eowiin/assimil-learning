import Foundation
import Testing
@testable import AssimilES

/// La voix des phrases du bloc 1 (étape 5c) : gardée une fois pour toutes, demandée par
/// paquets de 5, ou seule à la volée.
@MainActor
struct VoiceCacheTests {

    final class Service: AbsorptionService, @unchecked Sendable {
        var requests: [[String]] = []
        var failAfter: Int?

        func generate(_ request: AbsorptionRequest) async throws -> AbsorptionText {
            throw ServerError.server("pas de texte ici")
        }

        func speak(_ sentences: [String]) async throws -> [Data] {
            if let limit = failAfter, requests.count >= limit { throw ServerError.network("PC éteint") }
            requests.append(sentences)
            return sentences.map { Data("voz:\($0)".utf8) }
        }
    }

    static func wait(_ preparer: VoicePreparer) async {
        for _ in 0..<200 where preparer.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Une phrase se range sans ses espaces en trop ; un audio vide n'est pas gardé")
    func storage() throws {
        let root = AbsorptionTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VoiceCache.normalized("  Hola,\n  ¿qué tal? ") == "Hola, ¿qué tal?")
        #expect(VoiceCache.url(for: "Hola,  ¿qué tal?", root: root) == VoiceCache.url(for: "Hola, ¿qué tal?", root: root))
        #expect(VoiceCache.url(for: "¿Qué?", root: root) != VoiceCache.url(for: "qué", root: root))

        try VoiceCache.write(Data(), for: "Vacía.", root: root)
        #expect(VoiceCache.cached("Vacía.", root: root) == nil)
        try VoiceCache.write(Data("m4a".utf8), for: "Llena.", root: root)
        #expect(VoiceCache.cached(" Llena. ", root: root) != nil)
        #expect(VoiceCache.missing(["Llena.", "Otra.", "Otra. ", " "], root: root) == ["Otra."])
    }

    @Test("Une autre voix : le cache d'avant part, celui de la version en cours reste")
    func versions() throws {
        let base = AbsorptionTests.root()
        defer { try? FileManager.default.removeItem(at: base) }
        let current = base.appending(path: "v2", directoryHint: .isDirectory)
        let old = base.appending(path: "v1", directoryHint: .isDirectory)
        try VoiceCache.write(Data("nueva".utf8), for: "Hola.", root: current)
        try VoiceCache.write(Data("vieja".utf8), for: "Hola.", root: old)
        try Data("à plat".utf8).write(to: base.appending(path: "ancien.m4a"))

        VoiceCache.purgeOtherVersions(base: base, keeping: "v2")
        #expect(VoiceCache.cached("Hola.", root: current) != nil)
        #expect(VoiceCache.cached("Hola.", root: old) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["v2"])
    }

    @Test("Le bloc 1 : les exemples de la micro-leçon, puis les phrases du lexique, la plus récente d'abord")
    func blockOne() {
        let lesson = CurriculumPack.MicroLesson(objective: "obj_001", lines: [],
                                                examples: [.init(es: "Soy Ana.", fr: "Je suis Ana.")])
        let lexicon = LexiconWords(words: [
            .init(lemma: "mesa", sentence: "La mesa es grande.", form: nil, translation: ""),
            .init(lemma: "perro", sentence: "El perro duerme.", form: nil, translation: ""),
        ])
        #expect(VoiceCache.blockOneTexts(microlesson: lesson, lexicon: lexicon)
                == ["Soy Ana.", "El perro duerme.", "La mesa es grande."])
        #expect(VoiceCache.blockOneTexts(microlesson: nil, lexicon: .empty).isEmpty)
    }

    @Test("Par paquets de 5, seulement ce qui manque ; un paquet raté arrête, la suite reprend")
    func preparation() async throws {
        let root = AbsorptionTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try VoiceCache.write(Data("déjà".utf8), for: "Frase 0.", root: root)
        let texts = (0..<12).map { "Frase \($0)." }
        let service = Service()
        service.failAfter = 1

        let preparer = VoicePreparer(root: root)
        preparer.prepare(texts, service: service)
        await Self.wait(preparer)
        #expect(service.requests == [(1...5).map { "Frase \($0)." }])
        #expect(VoiceCache.missing(texts, root: root).count == 6)

        service.failAfter = nil
        preparer.prepare(texts, service: service)
        await Self.wait(preparer)
        #expect(service.requests.map(\.count) == [5, 5, 1])
        #expect(VoiceCache.missing(texts, root: root).isEmpty)
        let url = try #require(preparer.url(for: "Frase 11."))
        #expect(try Data(contentsOf: url) == Data("voz:Frase 11.".utf8))
        #expect(try Data(contentsOf: try #require(preparer.url(for: "Frase 0."))) == Data("déjà".utf8))
    }

    @Test("À la volée : le cache d'abord, sinon la phrase seule")
    func fetch() async throws {
        let root = AbsorptionTests.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = Service()
        let preparer = VoicePreparer(root: root)
        let url = try #require(await preparer.fetch(" El perro duerme. ", service: service))
        #expect(try Data(contentsOf: url) == Data("voz:El perro duerme.".utf8))
        #expect(await preparer.fetch("El perro duerme.", service: service) == url)
        #expect(service.requests == [["El perro duerme."]])
        #expect(!preparer.isFetching("El perro duerme."))
    }
}
