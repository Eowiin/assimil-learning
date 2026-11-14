import Foundation
import Observation

// MARK: - Ce qui circule avec le serveur

/// Une réplique, telle que le serveur la reçoit dans l'historique
/// (`server/app/conversation.py`, `Message`).
struct ConversationMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let role: Role
    let content: String
}

/// Le temps de chaque étape côté serveur, en secondes.
struct ConversationTimings: Decodable, Equatable, Sendable {
    let listen: Double?
    let think: Double
    let speak: Double
}

/// Une réplique de l'IA : le texte, et sa voix en AAC.
struct PartnerReply: Equatable, Sendable {
    let text: String
    let audio: Data
    let timings: ConversationTimings
}

/// Un tour : ce que le serveur a compris, et la réponse.
struct TurnReply: Equatable, Sendable {
    let heard: String
    let reply: PartnerReply
}

/// Une phrase fautive du récapitulatif.
struct ConversationCorrection: Codable, Equatable, Sendable {
    /// Le genre de faute, pour le profil d'apprenant.
    enum Category: String, Codable, Sendable {
        case grammar = "grammaire"
        case vocabulary = "vocabulaire"
        case phrasing = "tournure"
    }

    let said: String
    let corrected: String
    let explanation: String
    /// Absents des corrections gardées avant qu'on les demande au serveur : elles
    /// doivent toujours se lire.
    var category: Category? = nil
    /// Le point précis (« ser/estar »), en texte libre pour l'instant.
    var tag: String? = nil

    private enum CodingKeys: String, CodingKey { case said, corrected, explanation, category, tag }

    init(said: String, corrected: String, explanation: String, category: Category? = nil, tag: String? = nil) {
        self.said = said
        self.corrected = corrected
        self.explanation = explanation
        self.category = category
        self.tag = tag
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        said = try values.decode(String.self, forKey: .said)
        corrected = try values.decode(String.self, forKey: .corrected)
        explanation = try values.decode(String.self, forKey: .explanation)
        // Une catégorie inconnue ne doit pas faire perdre la correction entière.
        category = try? values.decodeIfPresent(Category.self, forKey: .category)
        tag = try? values.decodeIfPresent(String.self, forKey: .tag)
    }

    /// La phrase corrigée dit les mêmes mots que la phrase dite, une fois la casse,
    /// la ponctuation et les accents écrits mis de côté (comme `WordDiff`) : l'IA
    /// n'a « corrigé » que ce qu'a écrit la transcription, pas ce qu'a dit l'apprenant.
    var changesNothing: Bool {
        WordDiff.sameWords(said, corrected)
    }
}

/// Ce que l'écran attend du serveur. `ConversationClient` le joint par Tailscale ;
/// les tests passent un faux.
protocol ConversationService: Sendable {
    /// `profile` : ce que le partenaire sait de l'apprenant, nil sans profil.
    func start(topic: String?, profile: ConversationProfile?) async throws -> PartnerReply
    /// `audio` : l'enregistrement du tour. `text` le remplace, pour les tests.
    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?) async throws -> TurnReply
    func review(history: [ConversationMessage]) async throws -> [ConversationCorrection]
}

extension ConversationService {
    func start(topic: String?) async throws -> PartnerReply {
        try await start(topic: topic, profile: nil)
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage]) async throws -> TurnReply {
        try await turn(audio: audio, text: text, history: history, profile: nil)
    }
}

// MARK: - Le client

struct ConversationClient: ConversationService {
    let baseURL: URL
    var session: URLSession = .shared

    /// Le premier tour après une longue pause recharge l'IA dans Ollama : quelques
    /// secondes de plus, pas une panne.
    static let timeout: TimeInterval = 90

    private struct ReplyBody: Decodable {
        let reply: String
        let audio: String
        let timings: ConversationTimings
        let heard: String?

        func partner() throws -> PartnerReply {
            guard let data = Data(base64Encoded: audio) else {
                throw ServerError.server("Audio illisible dans la réponse du serveur")
            }
            return PartnerReply(text: reply, audio: data, timings: timings)
        }
    }

    private struct ReviewBody: Decodable { let corrections: [ConversationCorrection] }

    private struct StartBody: Encodable {
        let topic: String?
        let profile: ConversationProfile?
    }

    func start(topic: String?, profile: ConversationProfile?) async throws -> PartnerReply {
        let body = try JSONEncoder().encode(StartBody(topic: topic, profile: profile))
        return try await post("conversation/start", body: body, contentType: "application/json",
                              as: ReplyBody.self).partner()
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?) async throws -> TurnReply {
        let form = Self.form(audio: audio, text: text, history: history, profile: profile)
        let body = try await post("conversation/turn", body: form.body, contentType: form.contentType,
                                  as: ReplyBody.self)
        return TurnReply(heard: body.heard ?? "", reply: try body.partner())
    }

    func review(history: [ConversationMessage]) async throws -> [ConversationCorrection] {
        let body = try JSONEncoder().encode(["history": history])
        return try await post("conversation/review", body: body, contentType: "application/json",
                              as: ReviewBody.self).corrections
    }

    /// Le formulaire d'un tour : l'historique en JSON, puis l'audio ou le texte.
    static func form(audio: Data?, text: String?, history: [ConversationMessage], profile: ConversationProfile? = nil,
                     boundary: String = "assimil-\(UUID().uuidString)") -> (body: Data, contentType: String) {
        var form = MultipartForm(boundary: boundary)
        // Clés triées : le même historique donne toujours le même texte.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let historyJSON = (try? encoder.encode(history)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        form.field("history", historyJSON)
        if let profile, let json = (try? encoder.encode(profile)).flatMap({ String(data: $0, encoding: .utf8) }) {
            form.field("profile", json)
        }
        if let text { form.field("text", text) }
        if let audio { form.audio("audio", filename: "tour.m4a", audio) }
        return form.finished()
    }

    private func post<T: Decodable>(_ path: String, body: Data, contentType: String, as type: T.Type) async throws -> T {
        try await HomeServer.post(path, base: baseURL, body: body, contentType: contentType,
                                  timeout: Self.timeout, session: session, as: type)
    }
}

// MARK: - La conversation en cours

/// Une bulle de l'écran.
struct ConversationLine: Identifiable, Equatable {
    enum Speaker: Equatable { case learner, partner }
    let id = UUID()
    let speaker: Speaker
    let text: String
    /// La voix de l'IA, pour la réécouter. Nil pour l'apprenant.
    var audio: Data?
}

/// Ce que l'écran demande à l'audio : enregistrer un tour, jouer une réplique.
/// `ConversationAudio` (dans `Audio/`) passe par `VoiceRecorder` ; les tests, par un faux.
@MainActor
protocol ConversationSound: AnyObject {
    func begin()
    func end()
    /// Faux si le micro est refusé.
    func startRecording() async -> Bool
    func stopRecording() -> Data?
    func play(_ audio: Data, onFinish: @escaping @MainActor () -> Void)
    func stopPlayback()
}

/// Le talkie-walkie : l'IA ouvre, on touche le micro pour parler, on touche pour
/// envoyer, elle répond à voix haute. La règle est ici, l'écran affiche.
@Observable
@MainActor
final class ConversationSession {

    enum Phase: Equatable {
        /// L'IA prépare sa première réplique.
        case opening
        /// À l'apprenant de parler.
        case ready
        case recording
        /// Le serveur écoute, réfléchit, parle.
        case waiting
        /// Un échec : on garde le tour pour le renvoyer.
        case failed(String)
        case micDenied
    }

    /// Le récapitulatif, une fois la conversation terminée.
    enum Review: Equatable {
        case notStarted
        case loading
        case done([ConversationCorrection])
        case failed(String)
    }

    private(set) var lines: [ConversationLine] = []
    private(set) var phase: Phase = .opening
    private(set) var review: Review = .notStarted
    let startedAt: Date
    /// La bulle de l'IA en train d'être lue.
    private(set) var playingLine: ConversationLine.ID?
    /// Ce que le partenaire sait de l'apprenant, fixé avant l'ouverture et envoyé à
    /// chaque requête. Nil : la consigne d'avant le profil.
    var profile: ConversationProfile?

    private let service: any ConversationService
    private let sound: any ConversationSound
    /// Ce qui a échoué, à renvoyer tel quel : l'ouverture, ou l'audio d'un tour.
    private enum Pending { case opening, turn(Data) }
    private var pending: Pending?

    init(service: any ConversationService, sound: any ConversationSound, startedAt: Date = .now) {
        self.service = service
        self.sound = sound
        self.startedAt = startedAt
    }

    /// L'historique envoyé au serveur, qui ne garde rien.
    var history: [ConversationMessage] {
        lines.map { ConversationMessage(role: $0.speaker == .learner ? .user : .assistant, content: $0.text) }
    }

    var learnerSpoke: Bool { lines.contains { $0.speaker == .learner } }

    func open() async {
        sound.begin()
        guard lines.isEmpty else { return }
        await send(.opening)
    }

    func close() {
        if phase == .recording { _ = sound.stopRecording() }
        sound.stopPlayback()
        sound.end()
        playingLine = nil
    }

    /// Les corrections de toute la conversation. Sans phrase de l'apprenant, rien à
    /// demander. Se relance après un échec.
    func requestReview() async {
        guard learnerSpoke else {
            review = .done([])
            return
        }
        review = .loading
        do {
            // Une « correction » qui ne change aucun mot n'en est pas une : elle ne
            // s'affiche pas, et n'est pas gardée pour le profil.
            review = .done(try await service.review(history: history).filter { !$0.changesNothing })
        } catch {
            review = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Le bouton micro : un premier appui écoute, un second envoie.
    func toggleMic() async {
        switch phase {
        case .ready, .micDenied:
            sound.stopPlayback()
            playingLine = nil
            phase = await sound.startRecording() ? .recording : .micDenied
        case .recording:
            guard let audio = sound.stopRecording(), !audio.isEmpty else {
                phase = .ready
                return
            }
            await send(.turn(audio))
        case .opening, .waiting, .failed:
            break
        }
    }

    /// Abandonner une prise en cours, sans l'envoyer.
    func cancelRecording() {
        guard phase == .recording else { return }
        _ = sound.stopRecording()
        phase = .ready
    }

    func retry() async {
        guard case .failed = phase, let pending else { return }
        await send(pending)
    }

    func replay(_ line: ConversationLine) {
        guard let audio = line.audio, !audio.isEmpty, phase != .recording else { return }
        if playingLine == line.id {
            sound.stopPlayback()
            playingLine = nil
            return
        }
        play(line, audio: audio)
    }

    private func send(_ what: Pending) async {
        if case .opening = what { phase = .opening } else { phase = .waiting }
        pending = what
        do {
            let partner: ConversationLine
            switch what {
            case .opening:
                let reply = try await service.start(topic: nil, profile: profile)
                partner = ConversationLine(speaker: .partner, text: reply.text, audio: reply.audio)
            case .turn(let audio):
                let turn = try await service.turn(audio: audio, text: nil, history: history, profile: profile)
                lines.append(ConversationLine(speaker: .learner, text: turn.heard))
                partner = ConversationLine(speaker: .partner, text: turn.reply.text, audio: turn.reply.audio)
            }
            lines.append(partner)
            pending = nil
            phase = .ready
            if let audio = partner.audio, !audio.isEmpty { play(partner, audio: audio) }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func play(_ line: ConversationLine, audio: Data) {
        playingLine = line.id
        sound.play(audio) { [weak self] in
            guard let self, self.playingLine == line.id else { return }
            self.playingLine = nil
        }
    }
}

#if DEBUG
/// Le serveur imaginaire des tests d'interface (`ASSIMIL_FAKE_SERVER`).
struct FakeConversationService: ConversationService {
    func start(topic: String?, profile: ConversationProfile?) async throws -> PartnerReply {
        PartnerReply(text: "¡Hola! ¿Qué has hecho hoy?", audio: Data(),
                     timings: ConversationTimings(listen: nil, think: 0, speak: 0))
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?) async throws -> TurnReply {
        TurnReply(heard: text ?? "Hoy yo soy cansado.",
                  reply: PartnerReply(text: "¡Vaya! ¿Has dormido mal?", audio: Data(),
                                      timings: ConversationTimings(listen: 0, think: 0, speak: 0)))
    }

    func review(history: [ConversationMessage]) async throws -> [ConversationCorrection] {
        [ConversationCorrection(said: "Hoy yo soy cansado.", corrected: "Hoy estoy cansado.",
                                explanation: "Un état passager se dit avec « estar », pas avec « ser ».",
                                category: .grammar, tag: "ser/estar")]
    }
}

/// Le micro des tests d'interface : il « enregistre » sans demander l'autorisation
/// que le simulateur réclamerait, et ne joue rien.
@MainActor
final class SilentSound: ConversationSound {
    func begin() {}
    func end() {}
    func startRecording() async -> Bool { true }
    func stopRecording() -> Data? { Data("silence".utf8) }
    func play(_ audio: Data, onFinish: @escaping @MainActor () -> Void) { onFinish() }
    func stopPlayback() {}
}
#endif
