import Foundation
import Testing
@testable import AssimilES

/// Une réponse comme celle du serveur (`server/app/prononciation/jugement.py`) :
/// « Una jarra, por favor. » avec le r de « jarra » dit à la française, et le r
/// roulé de « por favor »… simple indice.
private let jarraJSON = """
{"words": [
  {"text": "una", "fault": false, "phonemes": [
    {"expected": "u", "heard": null, "fault": false, "reason": null, "hint": false, "tip": null,
     "score": 1.2, "threshold": -3.1, "start": 0.10, "end": 0.18},
    {"expected": "n", "heard": null, "fault": false, "reason": null, "hint": false, "tip": null,
     "score": 0.8, "threshold": -2.9, "start": 0.18, "end": 0.24},
    {"expected": "a", "heard": null, "fault": false, "reason": null, "hint": false, "tip": null,
     "score": 0.9, "threshold": -2.5, "start": 0.24, "end": 0.31}]},
  {"text": "jarra", "fault": true, "phonemes": [
    {"expected": "x", "heard": null, "fault": false, "reason": null, "hint": false, "tip": null,
     "score": 0.4, "threshold": -3.0, "start": 0.31, "end": 0.42},
    {"expected": "a", "heard": null, "fault": false, "reason": null, "hint": false, "tip": null,
     "score": 0.7, "threshold": -2.5, "start": 0.42, "end": 0.50},
    {"expected": "r", "heard": "ʁ", "fault": true, "reason": "r", "hint": false,
     "tip": "Le r se fait du bout de la langue, derrière les dents du haut, pas au fond de la gorge comme en français.",
     "score": null, "threshold": null, "start": 0.50, "end": 0.61},
    {"expected": "a", "heard": null, "fault": false, "reason": null, "hint": false, "tip": null,
     "score": 0.6, "threshold": -2.5, "start": 0.61, "end": 0.72}]},
  {"text": "por", "fault": false, "phonemes": [
    {"expected": "r", "heard": "ɾ", "fault": false, "reason": "r", "hint": true,
     "tip": "Le r roulé : plusieurs battements rapides du bout de la langue, derrière les dents du haut.",
     "score": null, "threshold": null, "start": 0.90, "end": 0.95}]},
  {"text": "favor", "fault": false, "phonemes": []}],
 "heard": "u n a ʁ a ...", "seconds": 0.21}
"""

// MARK: - Le client

@Suite("Prononciation : le client du serveur", .serialized)
struct PronunciationClientTests {

    private let base = URL(string: "https://pron.ts.net")!

    private func client(_ handler: @escaping StubProtocol.Handler) -> PronunciationClient {
        PronunciationClient(baseURL: base, session: StubProtocol.session(host: "pron.ts.net", handler))
    }

    @Test("La prise et la phrase partent en formulaire, le jugement revient décodé")
    func judge() async throws {
        var asked: URLRequest?
        let result = try await client { request in
            asked = request
            return (200, Data(jarraJSON.utf8))
        }.judge(audio: Data("prise".utf8), text: "Una jarra, por favor.")

        #expect(asked?.url?.absoluteString == "https://pron.ts.net/pronunciation")
        #expect(asked?.httpMethod == "POST")
        let body = String(decoding: asked?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#"name="text""#))
        #expect(body.contains("Una jarra, por favor."))
        #expect(body.contains(#"name="audio"; filename="phrase.m4a""#))
        #expect(body.contains("prise"))

        #expect(result.words.map(\.text) == ["una", "jarra", "por", "favor"])
        #expect(result.hasFault)
        #expect(result.seconds == 0.21)
        let r = result.words[1].phonemes[2]
        #expect(r.expected == "r" && r.heard == "ʁ" && r.fault && !r.hint)
        #expect(r.score == nil && r.start == 0.50)
        #expect(result.words[1].timeRange == 0.31...0.72)
        #expect(result.words[2].hasHint && !result.words[2].fault)
        #expect(result.words[3].timeRange == nil)
    }

    @Test("Prononciation pas chargée : la raison du serveur arrive telle quelle")
    func notLoaded() async {
        let failing = client { _ in (503, Data(#"{"detail":"La prononciation n'est pas chargée sur ce serveur."}"#.utf8)) }
        await #expect(throws: ServerError.server("La prononciation n'est pas chargée sur ce serveur.")) {
            try await failing.judge(audio: Data("prise".utf8), text: "Hola")
        }
    }

    @Test("Prise trop courte : 422, avec sa raison")
    func tooShort() async {
        let failing = client { _ in (422, Data(#"{"detail":"L'enregistrement est trop court."}"#.utf8)) }
        await #expect(throws: ServerError.server("L'enregistrement est trop court.")) {
            try await failing.judge(audio: Data("p".utf8), text: "Hola")
        }
    }

    @Test("PC introuvable : la même phrase que le voyant")
    func network() async {
        let failing = client { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: ServerError.network("PC introuvable : Tailscale est-il allumé ?")) {
            try await failing.judge(audio: Data("prise".utf8), text: "Hola")
        }
    }
}

// MARK: - Le rattachement aux mots affichés

@Suite("Prononciation : les mots jugés rattachés à la phrase")
struct PronunciationMatchTests {

    private func word(_ text: String, fault: Bool = false) -> JudgedWord {
        JudgedWord(text: text, fault: fault, phonemes: [])
    }

    @Test("Casse et ponctuation ne comptent pas")
    func punctuation() throws {
        let result = try JSONDecoder().decode(PronunciationResult.self, from: Data(jarraJSON.utf8))
        let shown = PronunciationMatch.attach(result.words, to: "Una jarra, por favor.")
        #expect(shown.map(\.text) == ["Una", "jarra,", "por", "favor."])
        #expect(shown.map(\.isFault) == [false, true, false, false])
        #expect(shown.map(\.hasHint) == [false, false, true, false])
        #expect(shown.allSatisfy { $0.judged != nil })
    }

    @Test("Les accents et les signes espagnols ne comptent pas")
    func accents() {
        let shown = PronunciationMatch.attach([word("¿qué"), word("está"), word("haciendo", fault: true)],
                                              to: "¿Qué estás haciendo?")
        // « está » ne couvre pas « estás » en entier, mais plus de la moitié : rattaché.
        #expect(shown.map { $0.judged?.text } == ["¿qué", "está", "haciendo"])
        #expect(shown[2].isFault)
    }

    @Test("Un nombre écrit en chiffres reste sans jugement, les autres mots gardent le leur")
    func digits() {
        let shown = PronunciationMatch.attach([word("tengo"), word("tres", fault: true), word("hermanos")],
                                              to: "Tengo 3 hermanos.")
        #expect(shown.map { $0.judged?.text } == ["tengo", nil, "hermanos"])
        #expect(!shown[1].isFault)
    }

    @Test("Un nombre suivi de sa lecture : les mots lus retrouvent leur place")
    func numberWithReading() {
        let shown = PronunciationMatch.attach(
            [word("en"), word("mil"), word("quinientos"), word("diecinueve", fault: true)],
            to: "En 1519 (mil quinientos diecinueve).")
        #expect(shown.map { $0.judged?.text } == ["en", nil, "mil", "quinientos", "diecinueve"])
        #expect(shown[4].isFault)
    }

    @Test("Une phrase qui ne correspond pas : rien n'est souligné")
    func unrelated() {
        let shown = PronunciationMatch.attach([word("perro", fault: true), word("grande")],
                                              to: "Buenos días.")
        #expect(shown.allSatisfy { $0.judged == nil })
    }

    @Test("Un mot jugé ne déborde pas sur deux mots affichés")
    func noSpanning() {
        // « porfavor » collé ne se rattache ni à « por » ni à « favor ».
        let shown = PronunciationMatch.attach([word("porfavor", fault: true)], to: "Por favor.")
        #expect(shown.allSatisfy { $0.judged == nil })
    }

    @Test("Sans réponse du serveur, la phrase s'affiche telle quelle")
    func noJudgement() {
        let shown = PronunciationMatch.attach([], to: "¡Hola, Laura!")
        #expect(shown.map(\.text) == ["¡Hola,", "Laura!"])
        #expect(shown.allSatisfy { $0.judged == nil && !$0.isFault })
    }
}

// MARK: - Les sons, dits en clair

@Suite("Prononciation : les sons dits en clair")
struct SpanishSoundsTests {

    private func phone(_ expected: String, heard: String?, fault: Bool = true, hint: Bool = false) -> JudgedPhone {
        JudgedPhone(expected: expected, heard: heard, fault: fault, reason: nil, hint: hint, tip: nil,
                    score: nil, threshold: nil, start: nil, end: nil)
    }

    @Test("Les fautes de francophone, sans alphabet phonétique")
    func corrections() {
        #expect(SpanishSounds.correction(for: phone("θ", heard: "s"))
                == "Tu as dit un s. Il faut le th anglais (« think »).")
        #expect(SpanishSounds.correction(for: phone("x", heard: "ʁ"))
                == "Tu as dit un r français, de gorge. Il faut la jota, raclée au fond de la gorge.")
        #expect(SpanishSounds.correction(for: phone("b", heard: "v"))
                == "Tu as dit un v, dents sur la lèvre. Il faut le b, lèvres qui se touchent à peine.")
    }

    @Test("Un son sauté, un son trop loin, un indice")
    func otherCases() {
        #expect(SpanishSounds.correction(for: phone("ɾ", heard: "∅")) == "Tu as sauté le r battu, un seul coup de langue.")
        #expect(SpanishSounds.correction(for: phone("e", heard: nil)) == "Ce son n'est pas encore le e (« é »).")
        #expect(SpanishSounds.correction(for: phone("r", heard: "ɾ", fault: false, hint: true))
                == "Indice : le r roulé est sorti comme le r battu, un seul coup de langue. Beaucoup de natifs le font.")
    }

    @Test("Un symbole inconnu reste tel quel, entre crochets")
    func unknown() {
        #expect(SpanishSounds.label("ʕ") == "[ʕ]")
    }
}

// MARK: - Le voyant

@Suite("Prononciation : le module annoncé par le serveur", .serialized)
@MainActor
struct PronunciationAvailabilityTests {

    private func status(modules: String) -> ServerStatus {
        ServerStatus(session: StubProtocol.session(host: "mod.ts.net") { _ in
            (200, Data(#"{"status":"ok","version":"0.2.0","api":1,"gpu":null,"modules":\#(modules)}"#.utf8))
        })
    }

    @Test("Annoncé : la prononciation est là")
    func announced() async {
        let server = status(modules: #"["conversation","pronunciation"]"#)
        await server.check(address: "mod.ts.net")
        #expect(server.pronunciation != nil)
        #expect(server.conversation != nil)
    }

    @Test("Pas annoncé : pas de prononciation, la conversation reste")
    func notAnnounced() async {
        let server = status(modules: #"["conversation"]"#)
        await server.check(address: "mod.ts.net")
        #expect(server.pronunciation == nil)
        #expect(server.conversation != nil)
    }

    @Test("Serveur hors ligne : ni l'une ni l'autre")
    func offline() async {
        let server = ServerStatus(session: StubProtocol.session(host: "off.ts.net") { _ in
            throw URLError(.timedOut)
        })
        await server.check(address: "off.ts.net")
        #expect(server.pronunciation == nil)
        #expect(server.conversation == nil)
    }
}
