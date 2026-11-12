import Foundation
import Observation

/// Ce que renvoie `GET /health` (`server/app/main.py`).
struct ServerHealth: Decodable, Equatable {
    let status: String
    let version: String
    let api: Int
    let gpu: String?
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
    private let session: URLSession
    /// Une vérification plus récente l'emporte sur une plus ancienne encore en route.
    private var generation = 0

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isOnline: Bool {
        if case .online = state { return true }
        return false
    }

    func check(address: String) async {
        generation += 1
        let current = generation
        let result = await Self.probe(address: address, session: session)
        if current == generation { state = result }
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
            return .offline(message(for: error))
        } catch {
            return .offline(error.localizedDescription)
        }
    }

    private static func message(for error: URLError) -> String {
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
