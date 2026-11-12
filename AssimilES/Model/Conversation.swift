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
    let said: String
    let corrected: String
    let explanation: String
}

enum ConversationError: LocalizedError, Equatable {
    /// Le serveur a répondu, avec une raison lisible (`detail` de FastAPI).
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .server(let reason), .network(let reason): reason
        }
    }
}

/// Ce que l'écran attend du serveur. `ConversationClient` le joint par Tailscale ;
/// les tests passent un faux.
protocol ConversationService: Sendable {
    func start(topic: String?) async throws -> PartnerReply
    /// `audio` : l'enregistrement du tour. `text` le remplace, pour les tests.
    func turn(audio: Data?, text: String?, history: [ConversationMessage]) async throws -> TurnReply
    func review(history: [ConversationMessage]) async throws -> [ConversationCorrection]
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
                throw ConversationError.server("Audio illisible dans la réponse du serveur")
            }
            return PartnerReply(text: reply, audio: data, timings: timings)
        }
    }

    private struct ReviewBody: Decodable { let corrections: [ConversationCorrection] }

    func start(topic: String?) async throws -> PartnerReply {
        let body = try JSONEncoder().encode(["topic": topic])
        return try await post("conversation/start", body: body, contentType: "application/json",
                              as: ReplyBody.self).partner()
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage]) async throws -> TurnReply {
        let form = Self.form(audio: audio, text: text, history: history)
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
    static func form(audio: Data?, text: String?, history: [ConversationMessage],
                     boundary: String = "assimil-\(UUID().uuidString)") -> (body: Data, contentType: String) {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        let historyJSON = (try? JSONEncoder().encode(history)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        field("history", historyJSON)
        if let text { field("text", text) }
        if let audio {
            body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; "
                              + "filename=\"tour.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n").utf8))
            body.append(audio)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private struct Detail: Decodable { let detail: String }

    private func post<T: Decodable>(_ path: String, body: Data, contentType: String, as: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ConversationError.network(HomeServer.message(for: error))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if let detail = try? JSONDecoder().decode(Detail.self, from: data) {
                throw ConversationError.server(detail.detail)
            }
            throw ConversationError.server(code == 502 ? "Le serveur n'est pas lancé sur le PC"
                                                       : "Erreur du serveur (code \(code))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ConversationError.server("Réponse illisible du serveur")
        }
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

    private(set) var lines: [ConversationLine] = []
    private(set) var phase: Phase = .opening
    /// La bulle de l'IA en train d'être lue.
    private(set) var playingLine: ConversationLine.ID?

    private let service: any ConversationService
    private let sound: any ConversationSound
    /// Ce qui a échoué, à renvoyer tel quel : l'ouverture, ou l'audio d'un tour.
    private enum Pending { case opening, turn(Data) }
    private var pending: Pending?

    init(service: any ConversationService, sound: any ConversationSound) {
        self.service = service
        self.sound = sound
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
                let reply = try await service.start(topic: nil)
                partner = ConversationLine(speaker: .partner, text: reply.text, audio: reply.audio)
            case .turn(let audio):
                let turn = try await service.turn(audio: audio, text: nil, history: history)
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
    func start(topic: String?) async throws -> PartnerReply {
        PartnerReply(text: "¡Hola! ¿Qué has hecho hoy?", audio: Data(),
                     timings: ConversationTimings(listen: nil, think: 0, speak: 0))
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage]) async throws -> TurnReply {
        TurnReply(heard: text ?? "He ido al mercado.",
                  reply: PartnerReply(text: "¡Qué bien! ¿Qué has comprado?", audio: Data(),
                                      timings: ConversationTimings(listen: 0, think: 0, speak: 0)))
    }

    func review(history: [ConversationMessage]) async throws -> [ConversationCorrection] { [] }
}
#endif
