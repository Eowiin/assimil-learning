import Foundation
import Testing
@testable import AssimilES

@Suite("Serveur de la maison : l'adresse")
struct HomeServerAddressTests {

    @Test("Un nom Tailscale nu devient une adresse https")
    func bareHostGetsHTTPS() {
        #expect(HomeServer.baseURL(from: "  pc.reseau.ts.net/ ")?.absoluteString == "https://pc.reseau.ts.net")
    }

    @Test("Une adresse complète est gardée, port compris")
    func fullAddressKept() {
        #expect(HomeServer.baseURL(from: "http://100.64.0.1:8000")?.absoluteString == "http://100.64.0.1:8000")
        #expect(HomeServer.healthURL(base: HomeServer.baseURL(from: "pc.ts.net")!).absoluteString
                == "https://pc.ts.net/health")
    }

    @Test("Vide ou d'un autre protocole : pas d'adresse")
    func invalidAddresses() {
        #expect(HomeServer.baseURL(from: "   ") == nil)
        #expect(HomeServer.baseURL(from: "ftp://pc.ts.net") == nil)
    }
}

@Suite("Serveur de la maison : le voyant", .serialized)
@MainActor
struct ServerStatusTests {

    private func status(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> ServerStatus {
        ServerStatus(session: StubProtocol.session(host: "pc.ts.net", handler))
    }

    private let healthy = Data(#"{"status":"ok","version":"0.1.0","api":1,"gpu":"NVIDIA GeForce RTX 5070 Ti"}"#.utf8)

    @Test("Le serveur répond : en ligne, avec sa carte graphique")
    func online() async {
        var asked: URL?
        let server = status { request in
            asked = request.url
            return (200, healthy)
        }
        await server.check(address: "pc.ts.net")
        #expect(asked?.absoluteString == "https://pc.ts.net/health")
        #expect(server.state == .online(ServerHealth(status: "ok", version: "0.1.0", api: 1,
                                                     gpu: "NVIDIA GeForce RTX 5070 Ti", modules: nil)))
        #expect(server.baseURL?.absoluteString == "https://pc.ts.net")
        // Un serveur 0.1 n'annonce aucun module : pas de conversation.
        #expect(server.conversation == nil)
        #expect(server.isOnline)
    }

    @Test("Pas d'adresse : aucun serveur, sans requête")
    func unset() async {
        var called = false
        let server = status { _ in called = true; return (200, Data()) }
        await server.check(address: " ")
        #expect(server.state == .unset)
        #expect(!called)
    }

    @Test("Tailscale répond 502 : le serveur n'est pas lancé")
    func notRunning() async {
        let server = status { _ in (502, Data()) }
        await server.check(address: "pc.ts.net")
        #expect(server.state == .offline("Le PC répond, mais le serveur n'est pas lancé"))
        #expect(!server.isOnline)
    }

    @Test("Une autre version d'API : hors ligne, avec la raison")
    func wrongAPI() async {
        let server = status { _ in (200, Data(#"{"status":"ok","version":"9","api":2,"gpu":null}"#.utf8)) }
        await server.check(address: "pc.ts.net")
        #expect(server.state == .offline("Serveur en version 2, l'app attend la 1"))
    }

    @Test("PC introuvable : on pense à Tailscale")
    func hostNotFound() async {
        let server = status { _ in throw URLError(.cannotFindHost) }
        await server.check(address: "pc.ts.net")
        #expect(server.state == .offline("PC introuvable : Tailscale est-il allumé ?"))
    }
}
