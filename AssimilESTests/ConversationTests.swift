import Foundation
import Testing
@testable import AssimilES

// MARK: - Le client

@Suite("Conversation : le client du serveur", .serialized)
struct ConversationClientTests {

    private let base = URL(string: "https://conv.ts.net")!

    private func client(_ handler: @escaping StubProtocol.Handler) -> ConversationClient {
        ConversationClient(baseURL: base, session: StubProtocol.session(host: "conv.ts.net", handler))
    }

    private func reply(_ text: String, heard: String? = nil) -> Data {
        var body: [String: Any] = ["reply": text, "audio": Data("m4a".utf8).base64EncodedString(),
                                   "timings": ["listen": NSNull(), "think": 0.14, "speak": 0.81]]
        if let heard { body["heard"] = heard }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    @Test("L'ouverture : la réplique, sa voix décodée, ses temps")
    func start() async throws {
        var asked: URLRequest?
        let opening = try await client { request in
            asked = request
            return (200, reply("¡Hola! ¿Qué tal?"))
        }.start(topic: nil)
        #expect(asked?.url?.absoluteString == "https://conv.ts.net/conversation/start")
        #expect(asked?.httpMethod == "POST")
        #expect(opening == PartnerReply(text: "¡Hola! ¿Qué tal?", audio: Data("m4a".utf8),
                                        timings: ConversationTimings(listen: nil, think: 0.14, speak: 0.81)))
    }

    @Test("Un tour : l'historique et l'audio partent en formulaire")
    func turn() async throws {
        var body = ""
        let history = [ConversationMessage(role: .assistant, content: "¿Qué has comido?")]
        let result = try await client { request in
            body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            return (200, reply("¡Qué rico!", heard: "Jamón de Jaén."))
        }.turn(audio: Data("prise".utf8), text: nil, history: history)
        #expect(result.heard == "Jamón de Jaén.")
        #expect(result.reply.text == "¡Qué rico!")
        #expect(body.contains(#"name="history""#))
        #expect(body.contains(#"[{"content":"¿Qué has comido?","role":"assistant"}]"#))
        #expect(body.contains(#"name="audio"; filename="tour.m4a""#))
        #expect(body.contains("prise"))
        #expect(!body.contains(#"name="text""#))
    }

    @Test("Le serveur dit pourquoi : sa raison arrive telle quelle")
    func serverDetail() async {
        let failing = client { _ in (503, Data(#"{"detail":"L'IA ne répond pas : Ollama est-il lancé sur le PC ?"}"#.utf8)) }
        await #expect(throws: ConversationError.server("L'IA ne répond pas : Ollama est-il lancé sur le PC ?")) {
            try await failing.turn(audio: nil, text: "Hola", history: [])
        }
    }

    @Test("PC introuvable : la même phrase que le voyant")
    func network() async {
        let failing = client { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: ConversationError.network("PC introuvable : Tailscale est-il allumé ?")) {
            try await failing.start(topic: nil)
        }
    }

    @Test("Le récapitulatif : les corrections")
    func review() async throws {
        let corrections = try await client { _ in
            (200, Data(#"{"corrections":[{"said":"Yo soy cansado","corrected":"Estoy cansado","explanation":"Un état : estar."}]}"#.utf8))
        }.review(history: [ConversationMessage(role: .user, content: "Yo soy cansado")])
        #expect(corrections == [ConversationCorrection(said: "Yo soy cansado", corrected: "Estoy cansado",
                                                       explanation: "Un état : estar.")])
    }
}

// MARK: - La conversation en cours

/// Un serveur qui répond ce qu'on lui dit, et note ce qu'il a reçu.
private final class ScriptedService: ConversationService, @unchecked Sendable {
    var failNext: ConversationError?
    var histories: [[ConversationMessage]] = []

    func start(topic: String?) async throws -> PartnerReply {
        if let error = failNext { failNext = nil; throw error }
        return PartnerReply(text: "¡Hola! ¿Qué has hecho hoy?", audio: Data("voix-0".utf8),
                            timings: ConversationTimings(listen: nil, think: 0, speak: 0))
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage]) async throws -> TurnReply {
        histories.append(history)
        if let error = failNext { failNext = nil; throw error }
        return TurnReply(heard: "He ido al mercado.",
                         reply: PartnerReply(text: "¿Qué has comprado?", audio: Data("voix-1".utf8),
                                             timings: ConversationTimings(listen: 0, think: 0, speak: 0)))
    }

    var corrections: [ConversationCorrection] = []
    var reviewed: [[ConversationMessage]] = []

    func review(history: [ConversationMessage]) async throws -> [ConversationCorrection] {
        reviewed.append(history)
        if let error = failNext { failNext = nil; throw error }
        return corrections
    }
}

@MainActor
private final class FakeSound: ConversationSound {
    var micAllowed = true
    var played: [Data] = []
    var finish: (@MainActor () -> Void)?
    var began = false

    func begin() { began = true }
    func end() { began = false }
    func startRecording() async -> Bool { micAllowed }
    func stopRecording() -> Data? { Data("prise".utf8) }
    func play(_ audio: Data, onFinish: @escaping @MainActor () -> Void) {
        played.append(audio)
        finish = onFinish
    }
    func stopPlayback() { finish = nil }
}

@Suite("Conversation : le talkie-walkie")
@MainActor
struct ConversationSessionTests {

    @Test("L'IA ouvre et sa réplique se fait entendre")
    func opens() async {
        let sound = FakeSound()
        let session = ConversationSession(service: ScriptedService(), sound: sound)
        await session.open()
        #expect(sound.began)
        #expect(session.lines.map(\.text) == ["¡Hola! ¿Qué has hecho hoy?"])
        #expect(session.phase == .ready)
        #expect(sound.played == [Data("voix-0".utf8)])
        #expect(session.playingLine == session.lines.first?.id)
        sound.finish?()
        #expect(session.playingLine == nil)
    }

    @Test("Un appui écoute, le second envoie : ce qui est compris, puis la réponse")
    func turn() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        await session.toggleMic()
        #expect(session.phase == .recording)
        await session.toggleMic()
        #expect(session.phase == .ready)
        #expect(session.lines.map(\.speaker) == [.partner, .learner, .partner])
        #expect(session.lines.map(\.text) == ["¡Hola! ¿Qué has hecho hoy?", "He ido al mercado.", "¿Qué has comprado?"])
        // Le serveur reçoit l'historique d'avant le tour, sans la phrase en cours.
        #expect(service.histories == [[ConversationMessage(role: .assistant, content: "¡Hola! ¿Qué has hecho hoy?")]])
        #expect(session.learnerSpoke)
    }

    @Test("Un échec garde le tour, et Réessayer le renvoie")
    func retry() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        service.failNext = .server("L'IA ne répond pas")
        await session.toggleMic()
        await session.toggleMic()
        #expect(session.phase == .failed("L'IA ne répond pas"))
        #expect(session.lines.count == 1)
        await session.retry()
        #expect(session.phase == .ready)
        #expect(session.lines.count == 3)
    }

    @Test("Une ouverture ratée se réessaie aussi")
    func openingRetry() async {
        let service = ScriptedService()
        service.failNext = .network("PC introuvable : Tailscale est-il allumé ?")
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        #expect(session.phase == .failed("PC introuvable : Tailscale est-il allumé ?"))
        await session.retry()
        #expect(session.lines.count == 1)
    }

    @Test("Micro refusé : on le dit, rien ne part")
    func micDenied() async {
        let sound = FakeSound()
        sound.micAllowed = false
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: sound)
        await session.open()
        await session.toggleMic()
        #expect(session.phase == .micDenied)
        #expect(service.histories.isEmpty)
    }

    @Test("Annuler une prise : rien n'est envoyé")
    func cancel() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        await session.toggleMic()
        session.cancelRecording()
        #expect(session.phase == .ready)
        #expect(service.histories.isEmpty)
    }
}

@Suite("Conversation : le récapitulatif")
@MainActor
struct ConversationReviewTests {

    private let correction = ConversationCorrection(said: "Yo soy cansado.", corrected: "Estoy cansado.",
                                                    explanation: "Un état passager se dit avec estar.")

    @Test("Le récapitulatif porte sur toute la conversation")
    func review() async {
        let service = ScriptedService()
        service.corrections = [correction]
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        await session.toggleMic()
        await session.toggleMic()
        await session.requestReview()
        #expect(session.review == .done([correction]))
        #expect(service.reviewed == [session.history])
        #expect(service.reviewed.first?.count == 3)
    }

    @Test("Sans phrase de l'apprenant, rien à demander")
    func nothingSaid() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        await session.requestReview()
        #expect(session.review == .done([]))
        #expect(service.reviewed.isEmpty)
    }

    @Test("Un échec se dit, et se relance")
    func failure() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        await session.toggleMic()
        await session.toggleMic()
        service.failNext = .server("L'IA ne répond pas")
        await session.requestReview()
        #expect(session.review == .failed("L'IA ne répond pas"))
        await session.requestReview()
        #expect(session.review == .done([]))
    }
}

@Suite("Conversation : les mots changés")
struct WordDiffTests {

    private func changed(_ words: [WordDiff.Word]) -> [String] {
        words.filter(\.changed).map(\.text)
    }

    @Test("Seul le mot remplacé ressort, des deux côtés")
    func replaced() {
        let diff = WordDiff.compare(said: "Yo soy cansado.", corrected: "Yo estoy cansado.")
        #expect(changed(diff.said) == ["soy"])
        #expect(changed(diff.corrected) == ["estoy"])
        #expect(diff.corrected.map(\.text) == ["Yo", "estoy", "cansado."])
    }

    @Test("Un mot ajouté, un mot retiré")
    func addedAndRemoved() {
        let diff = WordDiff.compare(said: "Me gusta los perros", corrected: "Me gustan los perros")
        #expect(changed(diff.said) == ["gusta"])
        #expect(changed(diff.corrected) == ["gustan"])
        let removed = WordDiff.compare(said: "Voy a el cine", corrected: "Voy al cine")
        #expect(changed(removed.said) == ["a", "el"])
        #expect(changed(removed.corrected) == ["al"])
    }

    @Test("Casse, ponctuation et accents écrits ne comptent pas : ils viennent de la transcription")
    func transcriptionNoise() {
        let diff = WordDiff.compare(said: "que tal, estas bien", corrected: "¿Qué tal? ¿Estás bien?")
        #expect(changed(diff.said).isEmpty)
        #expect(changed(diff.corrected).isEmpty)
    }
}
