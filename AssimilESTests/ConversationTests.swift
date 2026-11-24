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
        await #expect(throws: ServerError.server("L'IA ne répond pas : Ollama est-il lancé sur le PC ?")) {
            try await failing.turn(audio: nil, text: "Hola", history: [])
        }
    }

    @Test("PC introuvable : la même phrase que le voyant")
    func network() async {
        let failing = client { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: ServerError.network("PC introuvable : Tailscale est-il allumé ?")) {
            try await failing.start(topic: nil)
        }
    }

    @Test("Le profil part avec l'ouverture et avec chaque tour ; sans profil, rien")
    func profile() async throws {
        let profile = ConversationProfile(watch: "ser/estar", words: ["aprovechar"])
        var bodies: [String] = []
        let withProfile = client { request in
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            return (200, reply("¡Hola!", heard: "Hola."))
        }
        _ = try await withProfile.start(topic: nil, profile: profile)
        _ = try await withProfile.turn(audio: nil, text: "Hola", history: [], profile: profile)
        _ = try await withProfile.start(topic: nil)
        _ = try await withProfile.turn(audio: nil, text: "Hola", history: [])
        #expect(bodies[0].contains(#""profile":{"#))
        #expect(bodies[0].contains("aprovechar"))
        #expect(bodies[1].contains(#"name="profile""#))
        #expect(bodies[1].contains(#"{"watch":"ser\/estar","words":["aprovechar"]}"#))
        #expect(!bodies[2].contains("profile"))
        #expect(!bodies[3].contains("profile"))
    }

    @Test("Le récapitulatif : les corrections")
    func review() async throws {
        let corrections = try await client { _ in
            (200, Data(#"{"corrections":[{"said":"Yo soy cansado","corrected":"Estoy cansado","explanation":"Un état : estar."}]}"#.utf8))
        }.review(history: [ConversationMessage(role: .user, content: "Yo soy cansado")]).corrections
        #expect(corrections == [ConversationCorrection(said: "Yo soy cansado", corrected: "Estoy cansado",
                                                       explanation: "Un état : estar.")])
    }

    @Test("Le récapitulatif : la catégorie et le point de chaque faute")
    func reviewTagged() async throws {
        let corrections = try await client { _ in
            (200, Data(#"{"corrections":[{"said":"Yo soy cansado","corrected":"Estoy cansado","explanation":"Un état : estar.","category":"grammaire","tag":"ser/estar"}]}"#.utf8))
        }.review(history: [ConversationMessage(role: .user, content: "Yo soy cansado")]).corrections
        #expect(corrections.first?.category == .grammar)
        #expect(corrections.first?.tag == "ser/estar")
    }
}

@Suite("Conversation : les corrections")
struct ConversationCorrectionTests {

    @Test("Une correction gardée avant les étiquettes se lit toujours")
    func oldRecordStillReads() throws {
        let old = Data(#"[{"said":"Yo soy cansado.","corrected":"Estoy cansado.","explanation":"Un état : estar."}]"#.utf8)
        let record = ConversationRecord(startedAt: .now, endedAt: .now, messages: [])
        record.corrections = old
        let read = try #require(record.reviewedCorrections)
        #expect(read == [ConversationCorrection(said: "Yo soy cansado.", corrected: "Estoy cansado.",
                                                explanation: "Un état : estar.")])
        #expect(read.first?.category == nil)
        #expect(read.first?.tag == nil)
    }

    @Test("Les étiquettes se gardent avec la conversation")
    func tagsRoundTrip() throws {
        let record = ConversationRecord(startedAt: .now, endedAt: .now, messages: [])
        let tagged = ConversationCorrection(said: "Por mi es fácil.", corrected: "Para mí es fácil.",
                                            explanation: "Un point de vue se dit avec para.",
                                            category: .grammar, tag: "por/para")
        record.reviewedCorrections = [tagged]
        #expect(record.reviewedCorrections == [tagged])
    }

    @Test("Une catégorie inconnue ne fait pas perdre la correction")
    func unknownCategory() throws {
        let data = Data(#"{"said":"a","corrected":"b","explanation":"c","category":"style","tag":"x"}"#.utf8)
        let correction = try JSONDecoder().decode(ConversationCorrection.self, from: data)
        #expect(correction.category == nil)
        #expect(correction.tag == "x")
        #expect(correction.corrected == "b")
    }

    @Test("Une correction qui ne change aucun mot vient de la transcription")
    func changesNothing() {
        #expect(ConversationCorrection(said: "que tal, estas bien", corrected: "¿Qué tal? ¿Estás bien?",
                                       explanation: "").changesNothing)
        #expect(!ConversationCorrection(said: "Yo soy cansado.", corrected: "Yo estoy cansado.",
                                        explanation: "").changesNothing)
        #expect(!ConversationCorrection(said: "Voy a el cine", corrected: "Voy al cine",
                                        explanation: "").changesNothing)
    }
}

// MARK: - La conversation en cours

/// Un serveur qui répond ce qu'on lui dit, et note ce qu'il a reçu.
private final class ScriptedService: ConversationService, @unchecked Sendable {
    var failNext: ServerError?
    var histories: [[ConversationMessage]] = []

    var profiles: [ConversationProfile?] = []

    func start(topic: String?, profile: ConversationProfile?) async throws -> PartnerReply {
        profiles.append(profile)
        if let error = failNext { failNext = nil; throw error }
        return PartnerReply(text: "¡Hola! ¿Qué has hecho hoy?", audio: Data("voix-0".utf8),
                            timings: ConversationTimings(listen: nil, think: 0, speak: 0))
    }

    var closings: [Bool] = []
    /// Les débuts de réponse que le serveur joint à chaque réplique.
    var hints: [ConversationHint] = []

    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?, closing: Bool) async throws -> TurnReply {
        histories.append(history)
        profiles.append(profile)
        closings.append(closing)
        if let error = failNext { failNext = nil; throw error }
        return TurnReply(heard: "He ido al mercado.",
                         reply: PartnerReply(text: "¿Qué has comprado?", audio: Data("voix-1".utf8),
                                             timings: ConversationTimings(listen: 0, think: 0, speak: 0),
                                             hints: hints))
    }

    var corrections: [ConversationCorrection] = []
    var reviewed: [[ConversationMessage]] = []
    var reviewedObjectives: [ConversationObjective?] = []

    func review(history: [ConversationMessage], objective: ConversationObjective?,
                level: String?) async throws -> ConversationReview {
        reviewed.append(history)
        reviewedObjectives.append(objective)
        if let error = failNext { failNext = nil; throw error }
        return ConversationReview(corrections: corrections, lemmasProduced: ["ir", "mercado"])
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

    @Test("La séance envoie son profil à l'ouverture et à chaque tour")
    func sessionProfile() async {
        let service = ScriptedService()
        let profile = ConversationProfile(watch: "ser/estar", words: ["aprovechar"])
        let session = ConversationSession(service: service, sound: FakeSound())
        session.profile = profile
        await session.open()
        await session.toggleMic()
        await session.toggleMic()
        #expect(service.profiles == [profile, profile])
    }

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

    @Test("Une correction qui ne change aucun mot est écartée")
    func noiseDropped() async {
        let service = ScriptedService()
        let noise = ConversationCorrection(said: "he ido al mercado", corrected: "He ido al mercado.",
                                           explanation: "Il manque la majuscule.")
        service.corrections = [noise, correction]
        let session = ConversationSession(service: service, sound: FakeSound())
        await session.open()
        await session.toggleMic()
        await session.toggleMic()
        await session.requestReview()
        #expect(session.review == .done([correction]))
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
        #expect(WordDiff.sameWords("que tal, estas bien", "¿Qué tal? ¿Estás bien?"))
        #expect(WordDiff.sameWords("Hola , Laura", "¡Hola, Laura!"))
        #expect(!WordDiff.sameWords("Me gusta los perros", "Me gustan los perros"))
    }
}

// MARK: - Le moteur adaptatif (API 2)

@Suite("Conversation : le profil et le récapitulatif de l'API 2", .serialized)
@MainActor
struct ConversationAPI2Tests {

    static let objective = ConversationObjective(CurriculumPack.Objective(
        id: "obj_031", level: "A2", title: "Récit au passé", rule: "Imparfait et indefinido.",
        aiPrompt: "Demande un récit.", validation: "Les deux temps."))

    @Test("Le profil part avec le niveau, l'objectif et les lemmes connus ; vide, il ne les envoie pas")
    func profileEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let full = ConversationProfile(level: "A2", objective: Self.objective, allowedLemmas: ["ser", "casa"])
        let json = String(decoding: try encoder.encode(full), as: UTF8.self)
        #expect(json.contains(#""allowed_lemmas":["ser","casa"]"#))
        #expect(json.contains(#""level":"A2""#))
        #expect(json.contains(#""prompt_ia":"Demande un récit.""#))
        #expect(json.contains(#""titre":"Récit au passé""#))
        let old = ConversationProfile(watch: "ser/estar", words: ["aprovechar"])
        #expect(String(decoding: try encoder.encode(old), as: UTF8.self)
                == #"{"watch":"ser\/estar","words":["aprovechar"]}"#)
        #expect(try JSONDecoder().decode(ConversationProfile.self, from: encoder.encode(full)) == full)
    }

    @Test("Le récapitulatif envoie l'objectif et le niveau, et lit l'objectif jugé et les lemmes")
    func reviewWithObjective() async throws {
        var sent: [String: Any] = [:]
        let session = StubProtocol.session(host: "conv2.ts.net") { request in
            sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            return (200, Data(#"{"corrections":[],"objective_uses":[{"said":"Dormía cuando sonó","valide":true,"analyse_courte":"Les deux temps."}],"lemmas_produced":["dormir","sonar"]}"#.utf8))
        }
        let client = ConversationClient(baseURL: URL(string: "https://conv2.ts.net")!, session: session)
        let review = try await client.review(history: [ConversationMessage(role: .user, content: "Dormía cuando sonó")],
                                             objective: Self.objective, level: "A2")
        #expect(review.objectiveUses == [ObjectiveUse(said: "Dormía cuando sonó", valid: true, analysis: "Les deux temps.")])
        #expect(review.lemmasProduced == ["dormir", "sonar"])
        #expect(sent["level"] as? String == "A2")
        #expect((sent["objective"] as? [String: Any])?["id"] as? String == "obj_031")
    }

    @Test("Sans objectif ni spaCy, les champs nouveaux sont absents, pas une erreur")
    func reviewOld() async throws {
        let session = StubProtocol.session(host: "conv1.ts.net") { _ in (200, Data(#"{"corrections":[]}"#.utf8)) }
        let client = ConversationClient(baseURL: URL(string: "https://conv1.ts.net")!, session: session)
        let review = try await client.review(history: [])
        #expect(review == ConversationReview(corrections: []))
    }

    @Test("Le calibrage : le micro se tait après la limite, le récapitulatif reçoit l'objectif")
    func turnLimit() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        session.profile = ConversationProfile(level: "A2", objective: Self.objective)
        session.turnLimit = 1
        await session.open()
        await session.toggleMic()
        await session.toggleMic()
        #expect(session.learnerTurns == 1)
        #expect(session.reachedLimit)
        await session.toggleMic()
        #expect(session.phase == .ready)
        await session.requestReview()
        #expect(service.reviewedObjectives == [Self.objective])
        #expect(session.lastReview?.lemmasProduced == ["ir", "mercado"])
    }

    @Test("Le jeu de rôle (étape 5b) : la dernière réponse permise demande à l'IA de conclure ; pas le calibrage")
    func closesScene() async {
        let service = ScriptedService()
        let session = ConversationSession(service: service, sound: FakeSound())
        session.turnLimit = 2
        session.closesScene = true
        await session.open()
        for _ in 0..<2 {
            await session.toggleMic()
            await session.toggleMic()
        }
        #expect(service.closings == [false, true])
        #expect(session.reachedLimit)

        let calibration = ScriptedService()
        let other = ConversationSession(service: calibration, sound: FakeSound())
        other.turnLimit = 1
        await other.open()
        await other.toggleMic()
        await other.toggleMic()
        #expect(calibration.closings == [false])
    }

    @Test("Les amorces de la dernière réplique s'affichent quand c'est à l'apprenant, plus une fois la limite atteinte")
    func hints() async {
        let service = ScriptedService()
        let hints = [ConversationHint(es: "He comprado…", fr: "J'ai acheté…")]
        service.hints = hints
        let session = ConversationSession(service: service, sound: FakeSound())
        session.turnLimit = 2
        await session.open()
        // L'ouverture du faux n'en a pas.
        #expect(session.currentHints.isEmpty)
        await session.toggleMic()
        #expect(session.phase == .recording && session.currentHints.isEmpty)
        await session.toggleMic()
        #expect(session.currentHints == hints)
        await session.toggleMic()
        await session.toggleMic()
        #expect(session.reachedLimit && session.currentHints.isEmpty)
    }

    @Test("Le profil ne demande les amorces que s'il le faut ; le tour porte closing")
    func hintsWire() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = String(decoding: try encoder.encode(ConversationProfile(level: "B1")), as: UTF8.self)
        #expect(!plain.contains("hints"))
        let beginner = String(decoding: try encoder.encode(ConversationProfile(level: "A1", hints: true)), as: UTF8.self)
        #expect(beginner.contains("\"hints\":true"))
        let form = ConversationClient.form(audio: nil, text: "Hola", history: [], closing: true, boundary: "b")
        #expect(String(decoding: form.body, as: UTF8.self).contains("name=\"closing\"\r\n\r\ntrue"))
        let open = ConversationClient.form(audio: nil, text: "Hola", history: [], boundary: "b")
        #expect(!String(decoding: open.body, as: UTF8.self).contains("closing"))
    }
}
