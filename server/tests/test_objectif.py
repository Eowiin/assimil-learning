"""Étape 2c : le profil étendu (niveau, objectif, modes), la mesure de la réplique, le
récapitulatif qui juge l'objectif, et l'écrit. Un faux `Moteurs` (celui de
`test_conversation.py`) et un faux `Langue`."""

import base64
import json

import pytest
from fastapi.testclient import TestClient
from test_conversation import Faux

from app import main
from app.conversation import (CONSIGNE, OUVERTURE_ROLEPLAY, REECRITURES_AU_PLUS, SEUIL_REPLIQUE,
                              Correction, CorrectionEcrite, Corrections, CorrectionsEcrit,
                              CorrectionsEcritObjectif, CorrectionsObjectif, Objectif, Profil,
                              UsageObjectif, connus_du_tour, consigne, messages_ouverture,
                              mesurer, note_du_tour, vraies_corrections)
from app.langue import Langue, Mot
from app.llm import LLMIndisponible


class FausseLangue(Langue):
    """Un mot par espace, sans ponctuation ; un lemme par table."""
    nom = "faux"

    def __init__(self, lemmes: dict[str, str] | None = None):
        self.lemmes = lemmes or {}

    def mots(self, texte):
        formes = ("".join(c for c in f if c.isalpha()) for f in texte.lower().split())
        return [Mot(forme=f, lemme=self.lemmes.get(f, f)) for f in formes if f]


OBJ_031 = {
    "id": "obj_031",
    "titre": "Récit au passé : Contraste Indefinido vs Imperfecto",
    "regle": "Utiliser l'imparfait pour le décor et l'indefinido pour l'événement soudain "
             "(Dormía cuando sonó el teléfono).",
    "prompt_ia": "Demande à l'utilisateur de raconter une anecdote arrivée pendant un trajet.",
    "validation": "Combinaison réussie d'un imparfait de contexte et d'un passé simple d'événement.",
}
TITRE = OBJ_031["titre"]


def profil(**champs) -> Profil:
    return Profil(**champs)


# --- La consigne --------------------------------------------------------------------

def test_le_niveau_remplace_a2_b1():
    texte = consigne(profil(level="B2"))
    assert "nivel B2" in texte and "A2-B1" not in texte
    assert "sin simplificar" in texte
    # Sans niveau, la consigne d'avant.
    assert consigne(profil(watch="  ")) == CONSIGNE


def test_les_lemmes_connus_n_entrent_jamais_dans_la_consigne():
    p = profil(level="A2", objective=OBJ_031, allowed_lemmas=["zanahoria", "berenjena"])
    for mode in (None, "roleplay", "speed"):
        p.mode = mode
        texte = consigne(p) + "".join(m["content"] for m in messages_ouverture(None, p))
        assert "zanahoria" not in texte


def test_conversation_libre_l_objectif_amene_comme_watch():
    texte = consigne(profil(objective=OBJ_031))
    assert TITRE in texte and "Dormía cuando sonó" in texte
    assert "Nunca lo nombres" in texte
    # Le scénario n'est pas joué hors du jeu de rôle.
    assert "trajet" not in texte


def test_jeu_de_role_le_prompt_ia_sert_de_scenario():
    p = profil(objective=OBJ_031, mode="roleplay")
    assert "Juego de rol" in consigne(p) and OBJ_031["prompt_ia"] in consigne(p)
    assert messages_ouverture("el fútbol", p)[1]["content"].startswith(OUVERTURE_ROLEPLAY)
    # Le scénario amène l'objectif : la note ne le répète pas.
    assert note_du_tour(p, 0) is None


def test_jeu_de_role_sans_scenario_reste_une_conversation_libre():
    p = profil(objective={**OBJ_031, "prompt_ia": " "}, mode="roleplay")
    assert "Juego de rol" not in consigne(p)
    assert TITRE in note_du_tour(p, 0)


def test_mode_rapide_des_questions_courtes_qui_appellent_l_objectif():
    p = profil(objective=OBJ_031, mode="speed")
    assert "1 o 2 frases cortas como máximo" in consigne(p)
    assert "Ronda rápida" in consigne(p)
    # À chaque réplique, pas une sur trois.
    for rang in range(4):
        note = note_du_tour(p, rang)
        assert f"«{TITRE}»" in note and "una sola pregunta directa" in note
    assert "pocas palabras" in note_du_tour(p, 1)


def test_mode_rapide_ouverture_avec_sujet():
    contenu = messages_ouverture("los viajes", profil(mode="speed"))[1]["content"]
    assert "primera pregunta directa, sobre este tema: los viajes" in contenu


def test_objectif_et_watch_a_tour_de_role():
    p = profil(objective=OBJ_031, watch="ser/estar")
    points = {rang: note_du_tour(p, rang) for rang in range(7)}
    assert f"«{TITRE}»" in points[0] and f"«{TITRE}»" in points[6]
    assert "«ser/estar»" in points[3]
    assert points[1] is None


# --- La mesure de la réplique ------------------------------------------------------------

CONNUS = {"hola", "qué", "tal", "estás", "te", "gusta", "el", "la", "y"}


def reecrivain(*textes):
    """Une IA qui réécrit en rendant `textes` dans l'ordre, et note ses demandes."""
    demandes = []

    def repondre(messages):
        demandes.append(messages)
        texte = textes[len(demandes) - 1]
        if isinstance(texte, Exception):
            raise texte
        return texte

    return repondre, demandes


def test_assez_de_mots_connus_pas_de_reecriture():
    repondre, demandes = reecrivain()
    mesure = mesurer("Hola, ¿qué tal estás?", repondre, FausseLangue(), CONNUS)
    assert (mesure.texte, mesure.couverture, mesure.essais) == ("Hola, ¿qué tal estás?", 1.0, 1)
    assert demandes == []


def test_sous_le_seuil_l_ia_reecrit_avec_les_mots_inconnus():
    repondre, demandes = reecrivain("Hola, ¿te gusta el mar?")
    mesure = mesurer("Hola, ¿te apetece el senderismo?", repondre, FausseLangue(), CONNUS | {"mar"},
                     niveau="A1")
    assert mesure.texte == "Hola, ¿te gusta el mar?"
    assert (mesure.couverture, mesure.essais) == (1.0, 2)
    consigne_reecriture = demandes[0][0]["content"]
    assert "apetece, senderismo" in consigne_reecriture and "nivel A1" in consigne_reecriture
    assert demandes[0][1]["content"] == "Hola, ¿te apetece el senderismo?"


def test_deux_reecritures_au_plus_et_la_meilleure_gardee():
    premiere = "zzz yyy xxx hola"                     # 1/4
    meilleure = "«hola qué tal www»"                    # 3/4, guillemets ôtés
    pire = "hola vvv uuu ttt"                           # 1/4
    repondre, demandes = reecrivain(meilleure, pire, "jamais demandée")
    mesure = mesurer(premiere, repondre, FausseLangue(), CONNUS)
    assert len(demandes) == REECRITURES_AU_PLUS
    assert mesure.texte == "hola qué tal www" and mesure.couverture == 0.75
    assert mesure.essais == 3
    # La 2e réécriture part de la meilleure version, avec ses inconnus.
    assert demandes[1][1]["content"] == "hola qué tal www"
    assert "www" in demandes[1][0]["content"] and "zzz" not in demandes[1][0]["content"]


def test_une_reecriture_vide_ne_gagne_pas():
    repondre, _ = reecrivain("", "  «»  ")
    mesure = mesurer("zzz hola", repondre, FausseLangue(), CONNUS)
    assert mesure.texte == "zzz hola" and mesure.couverture == 0.5


def test_une_reecriture_commentee_ou_trop_longue_est_ecartee():
    commentee = ("¡Hola! ¿Qué **hiciste** ayer? → ¿Qué has hecho? *(Mantiene \"hiciste\" porque "
                 "es común)*")
    trop_longue = "hola qué tal " * 6
    repondre, demandes = reecrivain(commentee, trop_longue)
    mesure = mesurer("zzz hola qué tal", repondre, FausseLangue(), CONNUS)
    assert mesure.texte == "zzz hola qué tal" and mesure.essais == 3
    assert "sin asteriscos" in demandes[0][0]["content"]


def test_l_ia_tombe_pendant_la_reecriture_la_premiere_sert():
    repondre, _ = reecrivain(LLMIndisponible("Mistral ne répond pas : le PC a-t-il accès à internet ?"))
    mesure = mesurer("zzz hola", repondre, FausseLangue(), CONNUS)
    assert mesure.texte == "zzz hola" and mesure.essais == 2


def test_le_seuil():
    assert SEUIL_REPLIQUE == 0.85


def test_mots_appris_et_phrase_de_l_apprenant_comptent_comme_connus():
    langue = FausseLangue({"quedamos": "quedar"})
    connus = connus_du_tour(profil(allowed_lemmas=["Hola"], words=["aprovechar", "quedar con"]),
                            "Ayer quedamos en Sevilla", langue)
    assert {"hola", "aprovechar", "quedar", "con", "ayer", "quedamos", "en"} <= connus


# --- Les routes de la conversation -------------------------------------------------------

@pytest.fixture
def faux():
    return Faux()


def client_avec(faux, langue=None):
    return TestClient(main.create_app(moteurs=faux, charger=False, langue=langue))


PROFIL_MESURE = {"level": "A2", "objective": OBJ_031,
                 "allowed_lemmas": ["qué", "rico", "lo", "con", "pan", "hola", "te", "gusta"]}


def test_start_mesure_la_replique(faux):
    faux.repliques = ["¡Hola! ¡Qué rico! ¿Lo comes con pan?"]   # « comes » inconnu : 6/7
    corps = client_avec(faux, FausseLangue()).post(
        "/conversation/start", json={"profile": PROFIL_MESURE}).json()
    assert corps["coverage"] == pytest.approx(6 / 7, abs=1e-3)
    assert corps["attempts"] == 1
    # Les lemmes connus ne sont jamais envoyés à l'IA.
    assert "rico" not in faux.appels[0][0]["content"]


def test_start_reecrit_une_replique_trop_difficile(faux):
    faux.repliques = ["Hola, ¿te apetece el senderismo?", "Hola, ¿te gusta?"]
    corps = client_avec(faux, FausseLangue()).post(
        "/conversation/start", json={"profile": PROFIL_MESURE}).json()
    assert corps["reply"] == "Hola, ¿te gusta?"
    assert (corps["coverage"], corps["attempts"]) == (1.0, 2)
    # C'est la version gardée qui est dite.
    assert base64.b64decode(corps["audio"]).decode() == "m4a:Hola, ¿te gusta?"
    assert "apetece" in faux.appels[1][0]["content"]


def test_sans_langue_ou_sans_lemmes_pas_de_mesure(faux):
    corps = client_avec(faux).post("/conversation/start", json={"profile": PROFIL_MESURE}).json()
    assert corps["coverage"] is None and corps["attempts"] is None
    corps = client_avec(faux, FausseLangue()).post(
        "/conversation/start", json={"profile": {"level": "A2"}}).json()
    assert corps["coverage"] is None


def test_turn_la_phrase_de_l_apprenant_compte_comme_connue(faux):
    faux.repliques = ["¿Y comes jamón?"]
    profil_ = {"allowed_lemmas": ["y"]}
    corps = client_avec(faux, FausseLangue()).post(
        "/conversation/turn", data={"text": "Comes jamón cada día",
                                    "profile": json.dumps(profil_)}).json()
    assert corps["coverage"] == 1.0 and corps["attempts"] == 1
    assert corps["heard"] == "Comes jamón cada día"


# --- Le récapitulatif de la conversation ---------------------------------------------------

HISTORIQUE = [
    {"role": "assistant", "content": "¿Qué te pasó en el tren?"},
    {"role": "user", "content": "Yo leí un libro cuando el tren se paró"},
    {"role": "assistant", "content": "¡Vaya! ¿Y qué hiciste?"},
    {"role": "user", "content": "Llamé a mi madre."},
]


def test_review_avec_objectif(faux):
    faux.recap = CorrectionsObjectif(
        corrections=[
            Correction(said="Yo leí un libro cuando el tren se paró",
                       corrected="Yo leía un libro cuando el tren se paró",
                       explanation="Le décor se dit à l'imparfait.", category="grammaire",
                       tag="imparfait/indefinido"),
            # Une « correction » identique, à la casse, au point et aux accents près.
            Correction(said="Llamé a mi madre.", corrected="llame a mi madre", explanation="",
                       category="grammaire", tag="none"),
        ],
        objective_uses=[UsageObjectif(said="Yo leí un libro cuando el tren se paró", valide=False,
                                      analyse_courte="Le décor est à l'indefinido.")])
    corps = client_avec(faux, FausseLangue({"leí": "leer", "paró": "parar"})).post(
        "/conversation/review", json={"history": HISTORIQUE, "objective": OBJ_031,
                                      "level": "A2"}).json()
    assert faux.modele is CorrectionsObjectif
    assert [c["corrected"] for c in corps["corrections"]] == ["Yo leía un libro cuando el tren se paró"]
    assert corps["objective_uses"] == [{"said": "Yo leí un libro cuando el tren se paró",
                                        "valide": False,
                                        "analyse_courte": "Le décor est à l'indefinido."}]
    # Les lemmes de l'apprenant seul, par la langue, une fois chacun.
    assert corps["lemmas_produced"] == ["yo", "leer", "un", "libro", "cuando", "el", "tren", "se",
                                        "parar", "llamé", "a", "mi", "madre"]
    systeme = faux.messages[0]["content"]
    assert "niveau A2" in systeme and TITRE in systeme and OBJ_031["validation"] in systeme
    assert '"objective_uses"' in systeme


def test_review_sans_objectif_comme_avant(faux):
    corps = client_avec(faux).post("/conversation/review", json={"history": HISTORIQUE}).json()
    assert faux.modele is Corrections
    assert corps["objective_uses"] is None and corps["lemmas_produced"] is None
    assert "objective_uses" not in faux.messages[0]["content"]


def test_review_objectif_sans_phrase_de_l_eleve(faux):
    corps = client_avec(faux, FausseLangue()).post(
        "/conversation/review", json={"history": HISTORIQUE[:1], "objective": OBJ_031}).json()
    assert corps == {"corrections": [], "objective_uses": [], "lemmas_produced": []}
    assert faux.messages is None


def test_corrections_identiques_ecartees():
    def c(said, corrected):
        return Correction(said=said, corrected=corrected, explanation="", category="grammaire", tag="x")

    gardees = vraies_corrections([c("Yo soy cansado", "Estoy cansado"),
                                  c("¿Qué tal estás?", "que tal estas"),
                                  c("Fui  a Sevilla", "fui a sevilla.")])
    assert [g.said for g in gardees] == ["Yo soy cansado"]
    # À l'écrit, l'accent et la casse comptent : seule la phrase identique part.
    ecrites = vraies_corrections([c("que tal estas", "¿Qué tal estás?"), c("Hola  ya", "Hola ya")],
                                 ecrit=True)
    assert [e.said for e in ecrites] == ["que tal estas"]


# --- L'écrit -----------------------------------------------------------------------------

TEXTE = "Ayer yo estaba en casa cuando mi hermano llegó. El tenia frio."


def test_writing_review(faux):
    faux.recap = CorrectionsEcritObjectif(
        corrections=[CorrectionEcrite(said="El tenia frio.", corrected="Él tenía frío.",
                                      explanation="Accents écrits.", category="orthographe",
                                      tag="accent écrit"),
                     CorrectionEcrite(said="Ayer yo estaba en casa cuando mi hermano llegó.",
                                      corrected="Ayer yo estaba en casa cuando mi hermano llegó.",
                                      explanation="", category="grammaire", tag="none")],
        corrected_text="Ayer yo estaba en casa cuando mi hermano llegó. Él tenía frío.",
        objective_uses=[UsageObjectif(said="Ayer yo estaba en casa cuando mi hermano llegó.",
                                      valide=True, analyse_courte="Décor puis événement.")])
    corps = client_avec(faux, FausseLangue({"estaba": "estar"})).post(
        "/writing/review", json={"text": f"  {TEXTE} ", "level": "B1", "objective": OBJ_031}).json()
    assert faux.modele is CorrectionsEcritObjectif
    assert [c["category"] for c in corps["corrections"]] == ["orthographe"]
    assert corps["corrected_text"].endswith("Él tenía frío.")
    assert corps["objective_uses"][0]["valide"] is True
    assert "estar" in corps["lemmas_produced"] and "estaba" not in corps["lemmas_produced"]
    systeme = faux.messages[0]["content"]
    assert "niveau B1" in systeme and "accents écrits" in systeme and TITRE in systeme
    assert faux.messages[1]["content"] == TEXTE


def test_writing_review_sans_objectif_ni_langue(faux):
    faux.recap = CorrectionsEcrit(corrections=[], corrected_text=TEXTE)
    corps = client_avec(faux).post("/writing/review", json={"text": TEXTE}).json()
    assert faux.modele is CorrectionsEcrit
    assert corps == {"corrections": [], "corrected_text": TEXTE, "objective_uses": None,
                     "lemmas_produced": None}


def test_writing_review_texte_vide(faux):
    reponse = client_avec(faux).post("/writing/review", json={"text": "   "})
    assert reponse.status_code == 422
    assert reponse.json()["detail"] == "Il faut un texte."


def test_la_consigne_de_l_ecrit_n_est_pas_celle_de_l_oral(faux):
    faux.recap = CorrectionsEcrit(corrections=[], corrected_text=TEXTE)
    client_avec(faux).post("/writing/review", json={"text": TEXTE})
    assert "Whisper" not in faux.messages[0]["content"]
    assert "orthographe" in faux.messages[0]["content"]


def test_un_objectif_incomplet_est_refuse(faux):
    reponse = client_avec(faux).post("/writing/review", json={"text": TEXTE, "objective": {"id": "x"}})
    assert reponse.status_code == 422
