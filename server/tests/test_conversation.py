import base64
import json

import pytest
from fastapi.testclient import TestClient

from app import main
from app.conversation import (CONSIGNE, CONSIGNE_CORRECTION, Correction, Corrections, Profil, consigne,
                              note_du_tour)
from app.moteurs import OllamaIndisponible, Reglages


class Faux:
    """Des modèles qui répondent tout de suite, et notent ce qu'on leur a demandé."""

    def __init__(self, entendu="Me gusta el jamón de Jaén."):
        self.entendu = entendu
        self.messages = None
        self.contexte = "pas appelé"
        self.ollama_eteint = False

    def ecouter(self, audio: bytes, contexte: str | None = None) -> str:
        assert audio == b"audio-du-tour"
        self.contexte = contexte
        return self.entendu

    def repondre(self, messages):
        if self.ollama_eteint:
            raise OllamaIndisponible("connexion refusée")
        self.messages = messages
        return "¡Qué rico! ¿Lo comes con pan?"

    def corriger(self, messages):
        self.messages = messages
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


def test_la_note_du_tour_demande_un_mot_a_la_fois_et_le_point():
    profil = Profil(**PROFIL)
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
    assert faux.messages[1]["content"].endswith(note_du_tour(Profil(**PROFIL), 0))


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


def test_ollama_eteint_dit_quoi_faire(client, faux):
    faux.ollama_eteint = True
    reponse = client.post("/conversation/turn", data={"text": "Hola"})
    assert reponse.status_code == 503
    assert "Ollama" in reponse.json()["detail"]


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
    assert corps == {"corrections": []}
    assert faux.messages is None


# --- sans modèles ------------------------------------------------------------------

def test_sans_modeles_la_conversation_est_indisponible():
    client = TestClient(main.create_app(moteurs=None, charger=False))
    assert client.post("/conversation/start").status_code == 503
