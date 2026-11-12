import base64
import json

import pytest
from fastapi.testclient import TestClient

from app import main
from app.conversation import CONSIGNE, CONSIGNE_CORRECTION, Correction, Corrections
from app.moteurs import OllamaIndisponible


class Faux:
    """Des modèles qui répondent tout de suite, et notent ce qu'on leur a demandé."""

    def __init__(self, entendu="Me gusta el jamón de Jaén."):
        self.entendu = entendu
        self.messages = None
        self.ollama_eteint = False

    def ecouter(self, audio: bytes) -> str:
        assert audio == b"audio-du-tour"
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
            explanation="Un état passager se dit avec estar.")])

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
                                     "explanation": "Un état passager se dit avec estar."}]
    assert faux.messages[0] == {"role": "system", "content": CONSIGNE_CORRECTION}
    # La conversation passe en un seul texte, l'élève et son partenaire nommés.
    assert faux.messages[1]["content"] == ("Partenaire : Hola, ¿qué has comido hoy?\n"
                                           "Élève : Yo soy cansado")


def test_review_sans_phrase_de_l_eleve(client, faux):
    corps = client.post("/conversation/review", json={"history": HISTORIQUE}).json()
    assert corps == {"corrections": []}
    assert faux.messages is None


# --- sans modèles ------------------------------------------------------------------

def test_sans_modeles_la_conversation_est_indisponible():
    client = TestClient(main.create_app(moteurs=None, charger=False))
    assert client.post("/conversation/start").status_code == 503
