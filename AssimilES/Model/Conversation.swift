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

/// Un début de réponse proposé à un débutant (étape 5b), et sa traduction.
struct ConversationHint: Codable, Equatable, Sendable {
    let es: String
    let fr: String
}

/// Une réplique de l'IA : le texte, et sa voix en AAC.
struct PartnerReply: Equatable, Sendable {
    let text: String
    let audio: Data
    let timings: ConversationTimings
    /// Les débuts de réponse, quand le profil les demande (A0, A1).
    var hints: [ConversationHint] = []
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
        /// À l'écrit seulement (`/writing/review`).
        case spelling = "orthographe"
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

/// Un micro-objectif, tel que le serveur le reçoit (`server/app/conversation.py`,
/// `Objectif`) : l'app l'envoie en entier, le serveur n'a pas de copie du paquet.
struct ConversationObjective: Codable, Equatable, Sendable {
    let id: String
    let titre: String
    let regle: String
    let promptIA: String
    let validation: String

    init(_ objective: CurriculumPack.Objective) {
        id = objective.id
        titre = objective.title
        regle = objective.rule
        promptIA = objective.aiPrompt
        validation = objective.validation
    }

    private enum CodingKeys: String, CodingKey {
        case id, titre, regle, promptIA = "prompt_ia", validation
    }
}

/// Une phrase où l'apprenant a tenté l'objectif, jugée au récapitulatif.
struct ObjectiveUse: Codable, Equatable, Sendable {
    let said: String
    let valid: Bool
    let analysis: String

    private enum CodingKeys: String, CodingKey {
        case said, valid = "valide", analysis = "analyse_courte"
    }
}

/// Le récapitulatif : les corrections, et, en API 2, l'objectif jugé (null sans
/// objectif demandé) et les lemmes que l'apprenant a produits (null sans spaCy).
struct ConversationReview: Decodable, Equatable, Sendable {
    var corrections: [ConversationCorrection]
    var objectiveUses: [ObjectiveUse]? = nil
    var lemmasProduced: [String]? = nil

    private enum CodingKeys: String, CodingKey {
        case corrections, objectiveUses = "objective_uses", lemmasProduced = "lemmas_produced"
    }
}

/// Ce que l'écran attend du serveur. `ConversationClient` le joint par Tailscale ;
/// les tests passent un faux.
protocol ConversationService: Sendable {
    /// `profile` : ce que le partenaire sait de l'apprenant, nil sans profil.
    func start(topic: String?, profile: ConversationProfile?) async throws -> PartnerReply
    /// `audio` : l'enregistrement du tour. `text` le remplace, pour les tests. `closing` :
    /// la dernière réponse permise, l'IA conclut la scène.
    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?, closing: Bool) async throws -> TurnReply
    /// `objective` : l'objectif à juger dans les phrases de l'apprenant. `level` : son niveau.
    func review(history: [ConversationMessage], objective: ConversationObjective?,
                level: String?) async throws -> ConversationReview
}

extension ConversationService {
    func review(history: [ConversationMessage]) async throws -> ConversationReview {
        try await review(history: history, objective: nil, level: nil)
    }

    func start(topic: String?) async throws -> PartnerReply {
        try await start(topic: topic, profile: nil)
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage]) async throws -> TurnReply {
        try await turn(audio: audio, text: text, history: history, profile: nil, closing: false)
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?) async throws -> TurnReply {
        try await turn(audio: audio, text: text, history: history, profile: profile, closing: false)
    }
}

// MARK: - Le client

struct ConversationClient: ConversationService {
    let baseURL: URL
    var session: URLSession = .shared

    /// Mistral répond en quelques secondes ; une réplique trop difficile est réécrite,
    /// deux fois au plus, et le récapitulatif juge toute la conversation d'un coup.
    static let timeout: TimeInterval = 90

    private struct ReplyBody: Decodable {
        let reply: String
        let audio: String
        let timings: ConversationTimings
        let heard: String?
        let hints: [ConversationHint]?

        func partner() throws -> PartnerReply {
            guard let data = Data(base64Encoded: audio) else {
                throw ServerError.server("Audio illisible dans la réponse du serveur")
            }
            return PartnerReply(text: reply, audio: data, timings: timings, hints: hints ?? [])
        }
    }

    private struct ReviewRequest: Encodable {
        let history: [ConversationMessage]
        let objective: ConversationObjective?
        let level: String?
    }

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
              profile: ConversationProfile?, closing: Bool) async throws -> TurnReply {
        let form = Self.form(audio: audio, text: text, history: history, profile: profile, closing: closing)
        let body = try await post("conversation/turn", body: form.body, contentType: form.contentType,
                                  as: ReplyBody.self)
        return TurnReply(heard: body.heard ?? "", reply: try body.partner())
    }

    func review(history: [ConversationMessage], objective: ConversationObjective?,
                level: String?) async throws -> ConversationReview {
        let body = try JSONEncoder().encode(ReviewRequest(history: history, objective: objective, level: level))
        return try await post("conversation/review", body: body, contentType: "application/json",
                              as: ConversationReview.self)
    }

    /// Le formulaire d'un tour : l'historique en JSON, puis l'audio ou le texte.
    static func form(audio: Data?, text: String?, history: [ConversationMessage], profile: ConversationProfile? = nil,
                     closing: Bool = false,
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
        if closing { form.field("closing", "true") }
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
    /// Les débuts de réponse proposés sous cette réplique (A0, A1).
    var hints: [ConversationHint] = []
}

/// Ce que l'écran demande à l'audio : enregistrer un tour, jouer une réplique.
/// `ConversationAudio` (dans `Audio/`) passe par `VoiceRecorder` ; les tests, par un faux.
@MainActor
protocol ConversationSound: AnyObject {
    func begin()
    func end()
    /// Faux si le micro est refusé. `onVoice` : le moment où la voix arrive dans la
    /// prise, une fois au plus (le réflexe de la rafale).
    func startRecording(onVoice: @escaping @MainActor (Date) -> Void) async -> Bool
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
    /// Le nombre de réponses de l'apprenant au-delà duquel le micro se tait (le
    /// calibrage du placement, le jeu de rôle). Nil : sans limite.
    var turnLimit: Int?
    /// À la dernière réponse permise, l'IA conclut la scène au lieu de relancer (le jeu
    /// de rôle, étape 5b).
    var closesScene = false
    /// Le sujet que l'IA propose en ouvrant (le thème familier de la rafale). Nil : elle
    /// choisit.
    var topic: String?
    /// Le récapitulatif tel que le serveur l'a rendu, objectif et lemmes compris.
    private(set) var lastReview: ConversationReview?
    /// Mesurer le temps avant chaque réponse (la rafale du bloc 4, étape 5c-3).
    var measuresReflex = false
    private(set) var reflex = ReflexMeter()

    private let service: any ConversationService
    private let sound: any ConversationSound
    /// Ce qui a échoué, à renvoyer tel quel : l'ouverture, ou l'audio d'un tour.
    private enum Pending { case opening, turn(Data) }
    private var pending: Pending?
    /// Le top départ de la réponse : la fin de la dernière réplique de l'IA, ou l'appui
    /// sur le micro qui la coupe. Il reste posé après une prise annulée : hésiter compte.
    private var cue: Date?
    /// L'arrivée de la voix dans la prise en cours.
    private var onset: Date?
    private let now: () -> Date

    init(service: any ConversationService, sound: any ConversationSound, startedAt: Date = .now,
         now: @escaping () -> Date = { .now }) {
        self.service = service
        self.sound = sound
        self.startedAt = startedAt
        self.now = now
    }

    /// L'historique envoyé au serveur, qui ne garde rien.
    var history: [ConversationMessage] {
        lines.map { ConversationMessage(role: $0.speaker == .learner ? .user : .assistant, content: $0.text) }
    }

    var learnerSpoke: Bool { lines.contains { $0.speaker == .learner } }
    var learnerTurns: Int { lines.filter { $0.speaker == .learner }.count }
    var reachedLimit: Bool { turnLimit.map { learnerTurns >= $0 } ?? false }

    /// Les débuts de réponse à montrer : ceux de la dernière réplique, quand c'est à
    /// l'apprenant de parler.
    var currentHints: [ConversationHint] {
        guard phase == .ready, !reachedLimit, let last = lines.last, last.speaker == .partner else { return [] }
        return last.hints
    }

    /// Le tour qui part est le dernier permis.
    private var isLastTurn: Bool {
        closesScene && turnLimit.map { learnerTurns + 1 >= $0 } == true
    }

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
            let reviewed = try await service.review(history: history, objective: profile?.objective,
                                                    level: profile?.level)
            lastReview = reviewed
            review = .done(reviewed.corrections.filter { !$0.changesNothing })
        } catch {
            review = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Le bouton micro : un premier appui écoute, un second envoie.
    func toggleMic() async {
        switch phase {
        case .ready, .micDenied:
            guard !reachedLimit else { return }
            if measuresReflex, cue == nil { cue = now() }
            sound.stopPlayback()
            playingLine = nil
            onset = nil
            phase = await sound.startRecording { [weak self] time in self?.voiceStarted(at: time) }
                ? .recording : .micDenied
        case .recording:
            guard let audio = sound.stopRecording(), !audio.isEmpty else {
                onset = nil
                phase = .ready
                return
            }
            measureReflex()
            await send(.turn(audio))
        case .opening, .waiting, .failed:
            break
        }
    }

    /// Abandonner une prise en cours, sans l'envoyer.
    func cancelRecording() {
        guard phase == .recording else { return }
        _ = sound.stopRecording()
        onset = nil
        phase = .ready
    }

    private func voiceStarted(at time: Date) {
        guard phase == .recording, onset == nil else { return }
        onset = time
    }

    /// Le temps de la réponse qui part, compté une fois, avant le serveur : son délai
    /// n'est pas celui de l'apprenant. Une prise où la voix n'a pas été repérée ne
    /// compte pas, ni pour ni contre.
    private func measureReflex() {
        defer { cue = nil; onset = nil }
        guard measuresReflex, let cue, let onset else { return }
        reflex.record(max(0, onset.timeIntervalSince(cue)))
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
                let reply = try await service.start(topic: topic, profile: profile)
                partner = ConversationLine(speaker: .partner, text: reply.text, audio: reply.audio, hints: reply.hints)
            case .turn(let audio):
                let turn = try await service.turn(audio: audio, text: nil, history: history, profile: profile,
                                                  closing: isLastTurn)
                lines.append(ConversationLine(speaker: .learner, text: turn.heard))
                partner = ConversationLine(speaker: .partner, text: turn.reply.text, audio: turn.reply.audio,
                                           hints: turn.reply.hints)
            }
            lines.append(partner)
            pending = nil
            phase = .ready
            if let audio = partner.audio, !audio.isEmpty {
                play(partner, audio: audio)
            } else if measuresReflex {
                cue = now()
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func play(_ line: ConversationLine, audio: Data) {
        playingLine = line.id
        sound.play(audio) { [weak self] in
            guard let self, self.playingLine == line.id else { return }
            self.playingLine = nil
            // La réplique qui attend la réponse a fini : le temps de l'apprenant commence.
            if self.measuresReflex, self.phase == .ready, self.lines.last?.id == line.id, self.cue == nil {
                self.cue = self.now()
            }
        }
    }
}

#if DEBUG
/// Le serveur imaginaire des tests d'interface (`ASSIMIL_FAKE_SERVER`).
struct FakeConversationService: ConversationService {
    func start(topic: String?, profile: ConversationProfile?) async throws -> PartnerReply {
        PartnerReply(text: "¡Hola! ¿Qué has hecho hoy?", audio: Data(),
                     timings: ConversationTimings(listen: nil, think: 0, speak: 0),
                     hints: Self.hints(profile))
    }

    func turn(audio: Data?, text: String?, history: [ConversationMessage],
              profile: ConversationProfile?, closing: Bool) async throws -> TurnReply {
        TurnReply(heard: text ?? "Hoy yo soy cansado.",
                  reply: PartnerReply(text: closing ? "¡Que descanses! Hasta pronto." : "¡Vaya! ¿Has dormido mal?",
                                      audio: Data(), timings: ConversationTimings(listen: 0, think: 0, speak: 0),
                                      hints: closing ? [] : Self.hints(profile)))
    }

    private static func hints(_ profile: ConversationProfile?) -> [ConversationHint] {
        profile?.hints == true
            ? [ConversationHint(es: "Hoy he…", fr: "Aujourd'hui j'ai…"), ConversationHint(es: "Estoy…", fr: "Je suis…")]
            : []
    }

    func review(history: [ConversationMessage], objective: ConversationObjective?,
                level: String?) async throws -> ConversationReview {
        ConversationReview(
            corrections: [ConversationCorrection(said: "Hoy yo soy cansado.", corrected: "Hoy estoy cansado.",
                                                 explanation: "Un état passager se dit avec « estar », pas avec « ser ».",
                                                 category: .grammar, tag: "ser/estar")],
            // Avec un objectif, une tentative réussie et une manquée : le jeu de rôle de la
            // séance en tire deux preuves et une seule réussite.
            objectiveUses: objective == nil ? nil : [
                ObjectiveUse(said: "Hoy yo soy cansado.", valid: true, analysis: "L'objectif est employé."),
                ObjectiveUse(said: "¡Vaya!", valid: false, analysis: "Pas d'emploi correct de l'objectif."),
            ],
            lemmasProduced: ["hoy", "cansado"])
    }
}

/// Le micro des tests d'interface : il « enregistre » sans demander l'autorisation
/// que le simulateur réclamerait, et ne joue rien.
@MainActor
final class SilentSound: ConversationSound {
    func begin() {}
    func end() {}
    func startRecording(onVoice: @escaping @MainActor (Date) -> Void) async -> Bool {
        // Après le passage en écoute, comme un vrai micro.
        Task { @MainActor in onVoice(.now) }
        return true
    }
    func stopRecording() -> Data? { Data("silence".utf8) }
    func play(_ audio: Data, onFinish: @escaping @MainActor () -> Void) { onFinish() }
    func stopPlayback() {}
}
#endif
