import base64
import json

import pytest
from fastapi.testclient import TestClient

from app import main
from app.conversation import (CONSIGNE, CONSIGNE_CHERCHES, CONSIGNE_CORRECTION, DEMANDE, FIN_DE_SCENE,
                              Amorce, Amorces, Correction, Corrections, CorrectionsCherches,
                              MotCherche, Profil, amorces_propres, consigne, langue_d_ecoute,
                              mots_cherches_propres, note_du_tour, sans_francais)
from app.llm import LLMIndisponible
from app.moteurs import Reglages
from app.prises import Carnet


class Faux:
    """Des modèles qui répondent tout de suite, et notent ce qu'on leur a demandé."""

    def __init__(self, entendu="Me gusta el jamón de Jaén."):
        self.entendu = entendu
        self.messages = None
        self.contexte = "pas appelé"
        self.ia_eteinte = False
        # Les répliques à rendre, dans l'ordre (la première, puis les réécritures) ;
        # vide : toujours la même. `appels` : chaque demande faite à l'IA.
        self.repliques: list[str] = []
        self.appels: list[list[dict]] = []
        # Ce que rend `structurer` ; None : les corrections d'un récapitulatif simple.
        self.recap = None
        self.modele = None
        # Ce que rendent les amorces ; une exception : l'IA n'a pas pu les écrire.
        self.amorces: Amorces | Exception = Amorces(amorces=[
            Amorce(es="Quiero", fr="Je veux"), Amorce(es="Me gusta…", fr="J'aime…"),
            Amorce(es="quiero", fr="je veux"), Amorce(es="No sé si…", fr="Je ne sais pas si…"),
            Amorce(es="Prefiero…", fr="Je préfère…")])
        self.demandes_amorces: list[list[dict]] = []
        # Les mots cherchés que rend un récapitulatif de débutant (étape 6b).
        self.cherches: list[MotCherche] = []

    def ecouter(self, audio: bytes, contexte: str | None = None, langue: str = "es") -> str:
        assert audio == b"audio-du-tour"
        self.contexte = contexte
        self.langue = langue
        return self.entendu

    def repondre(self, messages):
        if self.ia_eteinte:
            raise LLMIndisponible("Mistral ne répond pas : le PC a-t-il accès à internet ?")
        self.appels.append(messages)
        if self.repliques:
            reponse = self.repliques.pop(0)
            if isinstance(reponse, Exception):
                raise reponse
            return reponse
        self.messages = messages
        return "¡Qué rico! ¿Lo comes con pan?"

    def structurer(self, messages, modele):
        if modele is Amorces:
            self.demandes_amorces.append(messages)
            if isinstance(self.amorces, Exception):
                raise self.amorces
            return self.amorces
        self.messages = messages
        self.modele = modele
        if self.recap is not None:
            return self.recap
        if modele is CorrectionsCherches:
            return CorrectionsCherches(searched=self.cherches)
        assert modele is Corrections
        return Corrections(corrections=[Correction(
            said="Yo soy cansado", corrected="Estoy cansado",
            explanation="Un état passager se dit avec estar.",
            category="grammaire", tag="ser/estar")])

    def dire(self, texte: str) -> bytes:
        return f"m4a:{texte}".encode()


@pytest.fixture
def faux():
    return Faux()


@pytest.fixture
def client(faux):
    return TestClient(main.create_app(moteurs=faux, charger=False))


def audio_de(reponse):
    return base64.b64decode(reponse["audio"]).decode()


# --- start -------------------------------------------------------------------------

def test_start_l_ia_ouvre_la_conversation(client, faux):
    corps = client.post("/conversation/start").json()
    assert corps["reply"] == "¡Qué rico! ¿Lo comes con pan?"
    assert audio_de(corps) == "m4a:¡Qué rico! ¿Lo comes con pan?"
    assert faux.messages[0] == {"role": "system", "content": CONSIGNE}
    assert faux.messages[1]["role"] == "user" and "Empieza tú" in faux.messages[1]["content"]
    assert set(corps["timings"]) == {"listen", "think", "speak"}


def test_start_avec_un_sujet(client, faux):
    client.post("/conversation/start", json={"topic": "el fútbol"})
    assert "el fútbol" in faux.messages[1]["content"]


# --- profil ------------------------------------------------------------------------

PROFIL = {"watch": "ser/estar", "words": ["aprovechar", "quedar con"]}


def test_sans_profil_la_consigne_ne_change_pas():
    assert consigne(None) == CONSIGNE
    assert consigne(Profil()) == CONSIGNE
    assert consigne(Profil(watch="  ", words=[" "])) == CONSIGNE


def test_le_profil_entre_dans_la_consigne():
    texte = consigne(Profil(**PROFIL))
    assert texte.startswith(CONSIGNE)
    assert "aprovechar, quedar con" in texte
    assert "«ser/estar»" in texte
    # Toujours sans corriger pendant l'échange.
    assert "no le corrijas" in texte


def test_la_consigne_demande_de_reagir_et_d_expliquer_un_mot_inconnu():
    assert "Reacciona primero a lo que acaba de decir" in CONSIGNE
    assert "no conoce o no entiende una palabra" in CONSIGNE


def test_la_note_du_tour_demande_un_mot_a_la_fois_et_le_point():
    profil = Profil(**PROFIL)
    # Répondre d'abord à ce qui vient d'être dit, avant ce que demande le profil.
    assert note_du_tour(profil, 0).index("primero responde") < note_du_tour(profil, 0).index("aprovechar")
    assert "«aprovechar»" in note_du_tour(profil, 0)
    assert "«quedar con»" in note_du_tour(profil, 1)
    assert "«aprovechar»" in note_du_tour(profil, 2)
    assert "«aprovechar»" not in note_du_tour(Profil(watch="ser/estar"), 0)


def test_le_point_a_l_ouverture_puis_une_replique_sur_trois_sans_options():
    profil = Profil(**PROFIL)
    avec_point = [rang for rang in range(7) if "«ser/estar»" in note_du_tour(profil, rang)]
    assert avec_point == [0, 3, 6]
    assert "sin ofrecer opciones" in note_du_tour(profil, 0)
    assert "nunca ofrezcas opciones" in consigne(profil)
    # Sans mots, une réplique sans le point n'a pas de note du tout.
    assert note_du_tour(Profil(watch="ser/estar"), 1) is None
    assert note_du_tour(None, 0) is None
    assert note_du_tour(Profil(), 3) is None


def test_cinq_mots_au_plus():
    texte = consigne(Profil(words=[f"palabra{i}" for i in range(8)]))
    assert "palabra4" in texte and "palabra5" not in texte


def test_start_avec_un_profil(client, faux):
    client.post("/conversation/start", json={"profile": PROFIL})
    assert faux.messages[0]["content"] == consigne(Profil(**PROFIL))
    assert faux.messages[1]["content"].endswith(note_du_tour(Profil(**PROFIL), 0, ouverture=True))
    # À l'ouverture, l'apprenant n'a encore rien dit.
    assert "acaba de decir" not in faux.messages[1]["content"]


def test_turn_avec_un_profil(client, faux):
    historique = [{"role": "assistant", "content": "¡Hola! ¿Qué tal?"}]
    corps = client.post("/conversation/turn", data={"text": "Hola", "history": json.dumps(historique),
                                                    "profile": json.dumps(PROFIL)}).json()
    assert faux.messages[0]["content"] == consigne(Profil(**PROFIL))
    # La note suit la phrase de l'apprenant ; une réplique de l'IA déjà faite : le 2e mot.
    assert faux.messages[-1]["content"] == "Hola\n\n" + note_du_tour(Profil(**PROFIL), 1)
    assert "«quedar con»" in faux.messages[-1]["content"]
    assert "«ser/estar»" not in faux.messages[-1]["content"]
    # Ce que l'app affiche et garde reste la phrase dite.
    assert corps["heard"] == "Hola"


def test_turn_sans_profil_la_phrase_seule(client, faux):
    client.post("/conversation/turn", data={"text": "Hola"})
    assert faux.messages[-1] == {"role": "user", "content": "Hola"}


def test_turn_profil_illisible(client):
    reponse = client.post("/conversation/turn", data={"text": "Hola", "profile": '{"words": "pas une liste"}'})
    assert reponse.status_code == 422
    assert reponse.json()["detail"].startswith("Profil illisible")


# --- turn --------------------------------------------------------------------------

HISTORIQUE = [{"role": "assistant", "content": "Hola, ¿qué has comido hoy?"}]


def test_turn_audio_ecoute_puis_repond(client, faux):
    corps = client.post("/conversation/turn",
                        data={"history": json.dumps(HISTORIQUE)},
                        files={"audio": ("tour.m4a", b"audio-du-tour", "audio/mp4")}).json()
    assert corps["heard"] == "Me gusta el jamón de Jaén."
    assert corps["reply"] == "¡Qué rico! ¿Lo comes con pan?"
    assert corps["timings"]["listen"] is not None
    # La consigne, puis l'historique de l'app, puis ce qui vient d'être compris.
    assert faux.messages == [{"role": "system", "content": CONSIGNE}, *HISTORIQUE,
                             {"role": "user", "content": "Me gusta el jamón de Jaén."}]


def test_turn_donne_a_l_ecoute_la_derniere_replique_de_l_ia(client, faux):
    historique = [*HISTORIQUE, {"role": "user", "content": "Paella."},
                  {"role": "assistant", "content": "¿Con marisco o con pollo?"}]
    client.post("/conversation/turn", data={"history": json.dumps(historique)},
                files={"audio": ("tour.m4a", b"audio-du-tour", "audio/mp4")})
    assert faux.contexte == "¿Con marisco o con pollo?"


def test_turn_sans_historique_pas_de_contexte(client, faux):
    client.post("/conversation/turn", files={"audio": ("tour.m4a", b"audio-du-tour", "audio/mp4")})
    assert faux.contexte is None


def test_l_amorce_de_whisper_est_desactivee_par_defaut(monkeypatch):
    monkeypatch.delenv("ASSIMIL_WHISPER_CONTEXTE", raising=False)
    assert Reglages.depuis_environnement().whisper_contexte is False
    monkeypatch.setenv("ASSIMIL_WHISPER_CONTEXTE", "1")
    assert Reglages.depuis_environnement().whisper_contexte is True


def test_turn_texte_a_la_place_de_l_audio(client, faux):
    corps = client.post("/conversation/turn", data={"text": " Hoy he comido paella. "}).json()
    assert corps["heard"] == "Hoy he comido paella."
    assert corps["timings"]["listen"] is None


def test_turn_sans_rien(client):
    reponse = client.post("/conversation/turn", data={"history": "[]"})
    assert reponse.status_code == 422
    assert reponse.json()["detail"] == "Il faut un audio ou un texte."


def test_turn_rien_entendu(faux):
    faux.entendu = ""
    client = TestClient(main.create_app(moteurs=faux, charger=False))
    reponse = client.post("/conversation/turn",
                          files={"audio": ("tour.m4a", b"audio-du-tour", "audio/mp4")})
    assert reponse.status_code == 422
    assert reponse.json()["detail"] == "Je n'ai rien entendu."


def test_turn_historique_illisible(client):
    reponse = client.post("/conversation/turn",
                          data={"history": '[{"role": "system", "content": "x"}]', "text": "Hola"})
    assert reponse.status_code == 422
    assert reponse.json()["detail"].startswith("Historique illisible")


def test_ia_eteinte_dit_quoi_faire(client, faux):
    faux.ia_eteinte = True
    reponse = client.post("/conversation/turn", data={"text": "Hola"})
    assert reponse.status_code == 503
    assert "Mistral" in reponse.json()["detail"]


# --- review ------------------------------------------------------------------------

def test_review_rend_les_corrections(client, faux):
    historique = [*HISTORIQUE, {"role": "user", "content": "Yo soy cansado"}]
    corps = client.post("/conversation/review", json={"history": historique}).json()
    assert corps["corrections"] == [{"said": "Yo soy cansado", "corrected": "Estoy cansado",
                                     "explanation": "Un état passager se dit avec estar.",
                                     "category": "grammaire", "tag": "ser/estar"}]
    assert faux.messages[0] == {"role": "system", "content": CONSIGNE_CORRECTION}
    # La conversation passe en un seul texte, l'élève et son partenaire nommés.
    assert faux.messages[1]["content"] == ("Partenaire : Hola, ¿qué has comido hoy?\n"
                                           "Élève : Yo soy cansado")


def test_le_format_impose_a_l_ia_porte_la_categorie_et_le_point():
    schema = Corrections.model_json_schema()["$defs"]["Correction"]
    assert schema["properties"]["category"]["enum"] == ["grammaire", "vocabulaire", "tournure"]
    assert {"category", "tag"} <= set(schema["required"])
    for mot in ('"category"', '"tag"', "ser/estar"):
        assert mot in CONSIGNE_CORRECTION


def test_la_consigne_previent_des_erreurs_de_transcription():
    assert "Whisper" in CONSIGNE_CORRECTION
    assert "Ne le corrige pas" in CONSIGNE_CORRECTION


def test_review_sans_phrase_de_l_eleve(client, faux):
    corps = client.post("/conversation/review", json={"history": HISTORIQUE}).json()
    assert corps == {"corrections": [], "objective_uses": None, "lemmas_produced": None,
                     "searched": None}
    assert faux.messages is None


# --- sans modèles ------------------------------------------------------------------

def test_sans_modeles_la_conversation_est_indisponible():
    client = TestClient(main.create_app(moteurs=None, charger=False))
    assert client.post("/conversation/start").status_code == 503


# --- Étape 5b : les amorces et la fin de scène ----------------------------------------

DEBUTANT = {"level": "A1", "hints": True}


def test_amorces_propres_trois_sans_doublon_finies_par_points():
    propres = amorces_propres(Amorces(amorces=[
        Amorce(es="Quiero.", fr="Je veux"), Amorce(es=" ", fr="vide"), Amorce(es="quiero…", fr="je veux"),
        Amorce(es="Me gusta", fr="J'aime"), Amorce(es="Prefiero", fr="Je préfère"), Amorce(es="Creo", fr="Je crois")]))
    assert [a.es for a in propres] == ["Quiero…", "Me gusta…", "Prefiero…"]
    assert all(a.fr.endswith("…") for a in propres)


def test_start_avec_amorces(client, faux):
    corps = client.post("/conversation/start", json={"profile": DEBUTANT}).json()
    assert [h["es"] for h in corps["hints"]] == ["Quiero…", "Me gusta…", "No sé si…"]
    assert corps["hints"][0]["fr"] == "Je veux…"
    # Les amorces répondent à la réplique que l'IA vient d'écrire.
    assert faux.demandes_amorces[0][-1]["content"].endswith("Compañero: ¡Qué rico! ¿Lo comes con pan?")
    assert "A1" in faux.demandes_amorces[0][0]["content"]


def test_sans_demande_pas_d_amorces(client, faux):
    corps = client.post("/conversation/start", json={"profile": {"level": "A1"}}).json()
    assert corps["hints"] is None
    assert faux.demandes_amorces == []


def test_amorces_ratees_la_replique_arrive_quand_meme(client, faux):
    faux.amorces = RuntimeError("Mistral ne répond pas")
    corps = client.post("/conversation/turn", data={"text": "Hola", "profile": json.dumps(DEBUTANT)}).json()
    assert corps["reply"] == "¡Qué rico! ¿Lo comes con pan?"
    assert corps["hints"] is None


def test_turn_amorces_voient_la_phrase_de_l_apprenant(client, faux):
    historique = [{"role": "assistant", "content": "¿Qué quieres comer?"}]
    client.post("/conversation/turn", data={"text": "Jamón", "history": json.dumps(historique),
                                            "profile": json.dumps(DEBUTANT)})
    assert faux.demandes_amorces[0][-1]["content"] == (
        "Compañero: ¿Qué quieres comer?\nEstudiante: Jamón\nCompañero: ¡Qué rico! ¿Lo comes con pan?")


def test_derniere_reponse_l_ia_conclut_sans_amorces(client, faux):
    corps = client.post("/conversation/turn", data={"text": "Adiós", "closing": "true",
                                                    "profile": json.dumps(DEBUTANT)}).json()
    assert faux.messages[-1]["content"] == "Adiós\n\n" + FIN_DE_SCENE
    assert corps["hints"] is None
    assert faux.demandes_amorces == []



# --- le crosstalk (étape 6b) ---------------------------------------------------------

AUDIO = {"audio": ("tour.m4a", b"audio-du-tour", "audio/mp4")}


def test_langue_d_ecoute():
    assert langue_d_ecoute(None) == "es"
    assert langue_d_ecoute(Profil(level="A0")) == "bilingue"
    assert langue_d_ecoute(Profil(level="A1")) == "bilingue"
    assert langue_d_ecoute(Profil(level="A2")) == "es"
    assert langue_d_ecoute(Profil(level="B1"), demande=True) == "fr"
    assert langue_d_ecoute(None, demande=True) == "fr"


@pytest.mark.parametrize(("niveau", "attendue"), [("A0", "bilingue"), ("B1", "es")])
def test_turn_ecoute_selon_le_niveau(client, faux, niveau, attendue):
    client.post("/conversation/turn", data={"profile": json.dumps({"level": niveau})}, files=AUDIO)
    assert faux.langue == attendue


def test_turn_sans_profil_ecoute_en_espagnol(client, faux):
    client.post("/conversation/turn", files=AUDIO)
    assert faux.langue == "es"


# --- Les prises gardées pour l'essai du crosstalk -----------------------------------

def test_sans_la_variable_aucune_prise_n_est_gardee(client):
    assert client.app.state.prises is None


def test_les_prises_des_debutants_sont_gardees_au_format_de_l_essai(client, faux, tmp_path):
    client.app.state.prises = Carnet(tmp_path / "prises")
    historique = json.dumps([{"role": "assistant", "content": "¿Qué quieres comer?"}])
    for _ in range(2):
        client.post("/conversation/turn", files=AUDIO, data={
            "profile": json.dumps({"level": "A0"}), "history": historique})
    assert (tmp_path / "prises" / "01.m4a").read_bytes() == b"audio-du-tour"
    assert (tmp_path / "prises" / "02.m4a").exists()
    notes = json.loads((tmp_path / "prises" / "entendu.json").read_text())
    assert notes["1"]["entendu"] == faux.entendu
    assert notes["1"]["replique"] == "¿Qué quieres comer?"


@pytest.mark.parametrize(("niveau", "demande"), [("B1", False), ("A0", True)])
def test_seules_les_prises_ecoutees_dans_les_deux_langues_sont_gardees(client, tmp_path, niveau, demande):
    client.app.state.prises = Carnet(tmp_path)
    client.post("/conversation/turn", files=AUDIO,
                data={"profile": json.dumps({"level": niveau}), "ask": str(demande).lower()})
    assert list(tmp_path.iterdir()) == []


def test_une_prise_qui_ne_se_garde_pas_ne_fait_pas_echouer_le_tour(client, tmp_path):
    bloque = tmp_path / "fichier"
    bloque.write_text("pas un dossier")
    client.app.state.prises = Carnet(bloque / "prises")
    reponse = client.post("/conversation/turn", files=AUDIO, data={"profile": json.dumps({"level": "A0"})})
    assert reponse.status_code == 200


def test_le_carnet_se_lit_dans_l_environnement(tmp_path):
    assert Carnet.depuis_environnement({}) is None
    assert Carnet.depuis_environnement({"ASSIMIL_GARDER_PRISES": str(tmp_path)}).dossier == tmp_path


def test_une_demande_s_ecoute_en_francais_et_l_ia_donne_le_mot(client, faux):
    faux.entendu = "couteau"
    profil = {"level": "A0", "words": ["aprovechar"]}
    corps = client.post("/conversation/turn", files=AUDIO,
                        data={"profile": json.dumps(profil), "ask": "true", "closing": "true"}).json()
    assert faux.langue == "fr"
    assert corps["heard"] == "couteau"
    derniere = faux.messages[-1]["content"]
    assert "«couteau»" in derniere and DEMANDE in derniere
    # Une demande n'est pas une réponse : ni fin de scène, ni la note habituelle du tour.
    assert FIN_DE_SCENE not in derniere and "aprovechar" not in derniere


def test_une_demande_passee_reste_une_demande_pour_l_ia(client, faux):
    historique = [*HISTORIQUE, {"role": "user", "content": "couteau", "ask": True},
                  {"role": "assistant", "content": "Un cuchillo. ¡Dilo tú!"}]
    client.post("/conversation/turn", data={"history": json.dumps(historique), "text": "Quiero un cuchillo"})
    demande = faux.messages[-3]
    # Le marqueur reste chez nous : l'API de Mistral n'accepte que le rôle et le texte.
    assert set(demande) == {"role", "content"}
    assert "«couteau»" in demande["content"] and "francés" in demande["content"]


def test_review_d_un_debutant_releve_les_mots_cherches(client, faux):
    faux.cherches = [MotCherche(fr="couteau", es="cuchillo", lemma="Cuchillo"),
                     MotCherche(fr="un couteau", es="un cuchillo", lemma="cuchillo"),
                     MotCherche(fr="", es="tenedor", lemma="tenedor")]
    historique = [*HISTORIQUE, {"role": "user", "content": "Quiero un couteau"}]
    corps = client.post("/conversation/review", json={"history": historique, "level": "A0"}).json()
    assert faux.modele is CorrectionsCherches
    assert CONSIGNE_CHERCHES in faux.messages[0]["content"]
    assert corps["searched"] == [{"fr": "couteau", "es": "cuchillo", "lemma": "cuchillo"}]


def test_review_au_dela_de_l_a1_ne_change_pas(client, faux):
    historique = [*HISTORIQUE, {"role": "user", "content": "Yo soy cansado"}]
    corps = client.post("/conversation/review", json={"history": historique, "level": "B1"}).json()
    assert faux.modele is Corrections
    assert CONSIGNE_CHERCHES not in faux.messages[0]["content"]
    assert corps["searched"] is None


def test_review_une_demande_suffit_et_se_dit_comme_telle(client, faux):
    historique = [*HISTORIQUE, {"role": "user", "content": "couteau", "ask": True}]
    corps = client.post("/conversation/review", json={"history": historique, "level": "B1"}).json()
    assert faux.modele is CorrectionsCherches
    assert "Élève (demande) : couteau" in faux.messages[1]["content"]
    assert corps["searched"] == []


def test_mots_cherches_propres():
    mots = [MotCherche(fr=" pain ", es=" pan ", lemma=" Pan "), MotCherche(fr="x", es="", lemma="y")]
    assert mots_cherches_propres(mots) == [MotCherche(fr="pain", es="pan", lemma="pan")]


def test_sans_francais():
    phrases = ["Quiero un… comment on dit… un couteau, por favor.", "Comment on dit", "Hola"]
    assert sans_francais(phrases, ["comment on dit", "un couteau"]) == [
        "Quiero un… … , por favor.", "Hola"]
    assert sans_francais(["Hola"], []) == ["Hola"]
