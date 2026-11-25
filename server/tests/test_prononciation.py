import subprocess

import numpy
import pytest
from fastapi.testclient import TestClient

from app import main, moteurs
from app.prononciation.jugement import CONSEILS, R_FRANCAIS, conseil, par_mots


def son(attendu="θ", **champs):
    return {"attendu": attendu, "mot": 0, "score": 1.0, "seuil": -3.2, "variante": "s",
            "faute": False, "raison": None, "debut": 0.1, "fin": 0.15, **champs}


# Ce que rend Analyseur.analyser pour « cinco perros » : le θ dit [s], le r roulé dit battu.
RESULTAT = {
    "mots": ["cinco", "perros"],
    "phonemes": [
        son(attendu="θ", score=-4.1, variante="s", faute=True, raison="gop"),
        son(attendu="i", variante="e"),
        son(attendu="r", mot=1, r="tap", indice="ɾ"),
        son(attendu="x", mot=1, score=None, variante=None, debut=None, fin=None),
    ],
    "entendu": ["s", "i", "ŋ", "k", "o"],
}


class FauxAnalyseur:
    def __init__(self, erreur=None):
        self.erreur = erreur
        self.recu = None

    def analyser(self, audio, phrase):
        if self.erreur:
            raise self.erreur
        self.recu = (len(audio), phrase)
        return RESULTAT


@pytest.fixture
def faux():
    return FauxAnalyseur()


@pytest.fixture
def client(faux, monkeypatch):
    # Pas de ffmpeg : 1 s de silence, ou un audio illisible.
    def decoder(audio):
        if audio == b"illisible":
            raise subprocess.CalledProcessError(1, "ffmpeg")
        return numpy.zeros(16000 if audio != b"court" else 1000, numpy.float32)

    monkeypatch.setattr(moteurs, "decoder_16k", decoder)
    return TestClient(main.create_app(charger=False, prononciation=faux))


def poster(client, audio=b"audio", text="Cinco perros"):
    return client.post("/pronunciation", data={"text": text},
                       files={"audio": ("phrase.m4a", audio, "audio/mp4")})


def test_juge_mot_par_mot(client, faux):
    corps = poster(client).json()
    assert faux.recu == (16000, "Cinco perros")
    cinco, perros = corps["words"]
    assert (cinco["text"], cinco["fault"]) == ("cinco", True)
    theta, i = cinco["phonemes"]
    assert theta | {"tip": None} == {"expected": "θ", "heard": "s", "fault": True, "reason": "gop",
                                     "hint": False, "tip": None, "score": -4.1, "threshold": -3.2,
                                     "start": 0.1, "end": 0.15}
    assert theta["tip"] == CONSEILS["θ"]
    assert i["heard"] is None and i["tip"] is None
    assert corps["heard"] == "s i ŋ k o"


def test_un_indice_ne_rend_pas_le_mot_fautif(client):
    perros = poster(client).json()["words"][1]
    r, x = perros["phonemes"]
    assert perros["fault"] is False
    assert (r["fault"], r["hint"], r["heard"], r["tip"]) == (False, True, "ɾ", CONSEILS["r"])
    assert x["score"] is None and x["start"] is None


def test_sans_prononciation_chargee():
    reponse = poster(TestClient(main.create_app(charger=False)))
    assert reponse.status_code == 503


@pytest.mark.parametrize("audio, text, message", [
    (b"audio", "  ", "phrase attendue"),
    (b"illisible", "Hola", "Audio illisible"),
    (b"court", "Hola", "trop court"),
])
def test_requetes_refusees(client, audio, text, message):
    reponse = poster(client, audio, text)
    assert reponse.status_code == 422
    assert message in reponse.json()["detail"]


def test_phrase_sans_mot(monkeypatch):
    monkeypatch.setattr(moteurs, "decoder_16k", lambda audio: numpy.zeros(16000, numpy.float32))
    app = main.create_app(charger=False, prononciation=FauxAnalyseur(ValueError("aucun mot à prononcer")))
    reponse = poster(TestClient(app), text="¿?")
    assert reponse.status_code == 422 and "aucun mot" in reponse.json()["detail"]


def test_health_annonce_la_prononciation(monkeypatch, faux):
    monkeypatch.setattr(main, "gpu_name", lambda: None)
    body = TestClient(main.create_app(charger=False, prononciation=faux)).get("/health").json()
    assert body["modules"] == ["pronunciation"]


def test_conseils():
    assert conseil("r", "ʁ") == R_FRANCAIS
    assert conseil("ɾ", "χ") == R_FRANCAIS
    assert conseil("b", "v") == CONSEILS["v"]
    assert conseil("b", "p") is None
    assert conseil("x", "ʒ") == CONSEILS["x"]


def test_par_mots_garde_l_ordre_des_sons():
    mots = par_mots(RESULTAT)
    assert [p["expected"] for m in mots for p in m["phonemes"]] == ["θ", "i", "r", "x"]
