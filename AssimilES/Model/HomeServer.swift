import Foundation
import Observation

/// Ce que renvoie `GET /health` (`server/app/main.py`).
struct ServerHealth: Decodable, Equatable {
    let status: String
    let version: String
    let api: Int
    let gpu: String?
    /// Les modules prêts sur le serveur (`conversation`). Absent avant la version 0.2.
    let modules: [String]?

    static let conversation = "conversation"
    static let pronunciation = "pronunciation"

    func has(_ module: String) -> Bool { modules?.contains(module) == true }
}

/// Le serveur de la maison : le PC fixe, joint par Tailscale (`docs/cadrage-v2.md`).
/// L'app ne gère pas la connexion. Tailscale le fait, et elle n'a qu'une adresse.
enum HomeServer {

    /// La forme des routes que cette version de l'app sait lire. Elle monte avec
    /// `API_VERSION` côté serveur.
    static let supportedAPI = 1

    /// La saisie des Réglages devient l'adresse de base du serveur.
    /// `nom-du-pc.reseau.ts.net` devient `https://nom-du-pc.reseau.ts.net` : Tailscale
    /// sert en HTTPS, et iOS refuse le HTTP simple hors du réseau local.
    static func baseURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    static func healthURL(base: URL) -> URL {
        base.appending(path: "health")
    }
}

/// Le voyant : le serveur répond-il ? Les modules qui en ont besoin ne se
/// montrent que s'il est en ligne (principe 4 du cadrage v2).
@Observable
@MainActor
final class ServerStatus {

    enum State: Equatable {
        /// Aucune adresse saisie : l'app marche sans serveur.
        case unset
        case checking
        case online(ServerHealth)
        case offline(String)
    }

    private(set) var state: State = .unset
    /// L'adresse du serveur, quand il répond.
    private(set) var baseURL: URL?
    private let session: URLSession
    #if DEBUG
    /// Les tests d'interface : un serveur imaginaire, en ligne, qui répond tout de suite.
    private var fake = false
    #endif
    /// Une vérification plus récente l'emporte sur une plus ancienne encore en route.
    private var generation = 0

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isOnline: Bool {
        if case .online = state { return true }
        return false
    }

    /// La conversation, si le serveur est en ligne et l'a chargée. Nil sinon : la
    /// ligne Conversation de l'accueil n'apparaît pas.
    var conversation: (any ConversationService)? {
        #if DEBUG
        if fake { return FakeConversationService() }
        #endif
        guard let baseURL = base(for: ServerHealth.conversation) else { return nil }
        return ConversationClient(baseURL: baseURL, session: session)
    }

    /// Le jugement des sons, si le serveur est en ligne et l'a chargé. Nil sinon : la
    /// ligne Prononciation de l'accueil n'apparaît pas.
    var pronunciation: (any PronunciationService)? {
        #if DEBUG
        if fake { return FakePronunciationService() }
        #endif
        guard let baseURL = base(for: ServerHealth.pronunciation) else { return nil }
        return PronunciationClient(baseURL: baseURL, session: session)
    }

    /// L'adresse du serveur, s'il est en ligne et annonce ce module.
    private func base(for module: String) -> URL? {
        guard case .online(let health) = state, health.has(module) else { return nil }
        return baseURL
    }

    /// Le serveur imaginaire des tests d'interface. En Release, un voyant ordinaire.
    static func fakeOnline() -> ServerStatus {
        let status = ServerStatus()
        #if DEBUG
        status.fake = true
        status.state = .online(ServerHealth(status: "ok", version: "test", api: HomeServer.supportedAPI,
                                            gpu: nil, modules: [ServerHealth.conversation,
                                                                ServerHealth.pronunciation]))
        #endif
        return status
    }

    func check(address: String) async {
        #if DEBUG
        if fake { return }
        #endif
        generation += 1
        let current = generation
        let result = await Self.probe(address: address, session: session)
        guard current == generation else { return }
        state = result
        baseURL = isOnline ? HomeServer.baseURL(from: address) : nil
    }

    private static func probe(address: String, session: URLSession) async -> State {
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unset }
        guard let base = HomeServer.baseURL(from: address) else {
            return .offline("Adresse invalide")
        }
        let request = URLRequest(url: HomeServer.healthURL(base: base), timeoutInterval: 5)
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // `tailscale serve` répond 502 quand rien n'écoute derrière lui.
            if code == 502 { return .offline("Le PC répond, mais le serveur n'est pas lancé") }
            guard code == 200 else { return .offline("Réponse inattendue (code \(code))") }
            guard let health = try? JSONDecoder().decode(ServerHealth.self, from: data) else {
                return .offline("Ce n'est pas le serveur de l'app")
            }
            guard health.api == HomeServer.supportedAPI else {
                return .offline("Serveur en version \(health.api), l'app attend la \(HomeServer.supportedAPI)")
            }
            return .online(health)
        } catch let error as URLError {
            return .offline(HomeServer.message(for: error))
        } catch {
            return .offline(error.localizedDescription)
        }
    }
}

/// Un appel au serveur qui a échoué, dit en clair.
enum ServerError: LocalizedError, Equatable {
    /// Le serveur a répondu, avec une raison lisible (`detail` de FastAPI).
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .server(let reason), .network(let reason): reason
        }
    }
}

/// Un formulaire `multipart/form-data`, pour envoyer une prise au serveur.
struct MultipartForm {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "assimil-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    /// Un fichier AAC (`audio/mp4`), comme le rend `VoiceRecorder`.
    mutating func audio(_ name: String, filename: String, _ data: Data) {
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; "
                          + "filename=\"\(filename)\"\r\nContent-Type: audio/mp4\r\n\r\n").utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// Le corps clos, et l'en-tête qui va avec.
    func finished() -> (body: Data, contentType: String) {
        var closed = body
        closed.append(Data("--\(boundary)--\r\n".utf8))
        return (closed, "multipart/form-data; boundary=\(boundary)")
    }
}

extension HomeServer {

    private struct Detail: Decodable { let detail: String }

    /// Un POST au serveur, et sa réponse décodée. Toute erreur devient une
    /// `ServerError` qu'on peut afficher telle quelle.
    static func post<T: Decodable>(_ path: String, base: URL, body: Data, contentType: String,
                                   timeout: TimeInterval, session: URLSession, as: T.Type) async throws -> T {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ServerError.network(message(for: error))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if let detail = try? JSONDecoder().decode(Detail.self, from: data) {
                throw ServerError.server(detail.detail)
            }
            throw ServerError.server(code == 502 ? "Le serveur n'est pas lancé sur le PC"
                                                 : "Erreur du serveur (code \(code))")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServerError.server("Réponse illisible du serveur")
        }
    }

    /// Une erreur réseau, dite pour quelqu'un qui sait où est son PC.
    static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: "Pas de réseau"
        case .cannotFindHost, .dnsLookupFailed: "PC introuvable : Tailscale est-il allumé ?"
        case .timedOut: "Le PC ne répond pas : est-il allumé ?"
        case .cannotConnectToHost: "Connexion refusée : le serveur est-il lancé ?"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            "Certificat refusé : HTTPS est-il activé dans Tailscale ?"
        case .appTransportSecurityRequiresSecureConnection: "Il faut une adresse en https"
        default: error.localizedDescription
        }
    }
}
