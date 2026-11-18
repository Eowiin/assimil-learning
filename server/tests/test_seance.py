"""Étape 2d : le placement (trois verdicts), le texte du bloc 2 et la voix phrase par
phrase. Le faux `Moteurs` de `test_conversation.py`, étendu de `rediger`, et le faux
`Langue` de `test_objectif.py`."""

import base64
import re

import pytest
from fastapi.testclient import TestClient
from test_conversation import Faux
from test_objectif import OBJ_031, FausseLangue

from app import main
from app.llm import LLMIndisponible
from app.placement import (DEJA_ATTENDUE, PAR_PAQUET, Defi, JugementNumerote, Jugements, evaluer,
                           messages_placement, trier)
from app.seance import (InputRequest, Phrase, PhraseJugee, Redaction, Reperage, generer, presents,
                        reperer)

# --- Le placement -------------------------------------------------------------------

PC_001 = {
    "objective_id": "obj_001",
    "instruction": "Il est 16 h : dis cette phrase en espagnol à un ami.",
    "prompt": "Bonjour ! Comment vas-tu ?",
    "expected": ["¡Buenas tardes! ¿Cómo estás?", "¡Buenas tardes! ¿Qué tal?"],
    "also_correct": ["Hola, ¿qué tal?"],
    "check": "La salutation est « buenas tardes » (16 h).",
}


def defi(answer: str, objective_id: str = "obj_001") -> Defi:
    return Defi(**{**PC_001, "objective_id": objective_id, "answer": answer})


class Juge:
    """Un faux juge : rend un verdict par numéro demandé, sauf ceux qu'il « oublie »."""

    def __init__(self, verdict="wrong", oublier: set[str] = frozenset(), toujours: bool = False):
        self.verdict = verdict
        self.oublier = oublier
        self.toujours = toujours
        self.appels: list[list[dict]] = []

    def __call__(self, messages, modele):
        assert modele is Jugements
        self.appels.append(messages)
        texte = messages[1]["content"]
        defis = texte.split("\n\n")
        jugements = []
        for numero, bloc in enumerate(defis, 1):
            seul = len(defis) == 1
            if any(o in bloc for o in self.oublier) and (self.toujours or not seul):
                continue
            jugements.append(JugementNumerote(numero=numero, verdict=self.verdict,
                                              analyse_courte="Pourquoi."))
        return Jugements(jugements=jugements)


def test_le_tri_sans_ia():
    assert trier(defi("  ")).verdict == "wrong"
    # Casse, ponctuation et ¿ ¡ ne comptent pas ; les accents, si.
    assert trier(defi("buenas tardes, cómo estás")).verdict == "shown"
    assert trier(defi("buenas tardes, cÓmo estás")).analyse_courte == DEJA_ATTENDUE
    assert trier(defi("hola qué tal")).verdict == "correct_not_shown"
    assert trier(defi("buenas tardes, como estas")) is None
    assert trier(defi("Buenos días")) is None


def test_seules_les_reponses_libres_vont_au_juge():
    juge = Juge("shown")
    verdicts = evaluer([defi("¡Buenas tardes! ¿Cómo estás?"), defi("Buenas tardes, ¿cómo te va?"),
                        defi("")], juge, "A1")
    assert [v.verdict for v in verdicts] == ["shown", "shown", "wrong"]
    assert len(juge.appels) == 1
    envoye = juge.appels[0][1]["content"]
    assert "cómo te va" in envoye and "Défi 2" not in envoye
    assert "niveau estimé A1" in juge.appels[0][0]["content"]


def test_la_consigne_et_la_mise_en_situation():
    messages = messages_placement([defi("Buenos días")], "A2")
    systeme, defis = messages[0]["content"], messages[1]["content"]
    assert "correct_not_shown" in systeme and "debe de estar" in systeme
    assert "Le type d'exercice" in systeme
    assert "Il est 16 h" in defis
    assert "« Hola, ¿qué tal? »" in defis
    assert "Réponse de l'élève : « Buenos días »" in defis
    # Sans `also_correct`, le juge le sait.
    sans = Defi(**{**PC_001, "also_correct": [], "answer": "x"})
    assert "le contournent : aucune" in messages_placement([sans])[1]["content"]


def test_l_analyse_avant_le_verdict():
    # Le juge écrit dans l'ordre du schéma : le verdict suit son analyse.
    assert list(JugementNumerote.model_fields) == ["numero", "analyse_courte", "verdict"]
    assert "ne lui prête aucun mot" in messages_placement([defi("x")])[0]["content"]


def test_par_paquets_et_dans_l_ordre():
    juge = Juge("wrong")
    defis = [defi(f"respuesta {i}", f"obj_{i:03}") for i in range(PAR_PAQUET + 3)]
    verdicts = evaluer(defis, juge)
    assert len(juge.appels) == 2
    assert [v.objective_id for v in verdicts] == [d.objective_id for d in defis]


def test_un_numero_hors_paquet_est_ecarte():
    def juge(messages, modele):
        return Jugements(jugements=[JugementNumerote(numero=7, verdict="shown", analyse_courte="?"),
                                    JugementNumerote(numero=1, verdict="wrong", analyse_courte="!")])

    assert [v.verdict for v in evaluer([defi("Buenos días")], juge)] == ["wrong"]


def test_un_defi_oublie_est_rejuge_seul():
    juge = Juge("wrong", oublier={"respuesta 1"})
    verdicts = evaluer([defi("respuesta 0", "obj_000"), defi("respuesta 1", "obj_001")], juge)
    assert len(juge.appels) == 2
    assert "respuesta 1" in juge.appels[1][1]["content"]
    assert "respuesta 0" not in juge.appels[1][1]["content"]
    assert [v.objective_id for v in verdicts] == ["obj_000", "obj_001"]


def test_un_defi_oublie_deux_fois_est_une_erreur():
    with pytest.raises(LLMIndisponible, match="obj_001"):
        evaluer([defi("respuesta 1")], Juge(oublier={"respuesta 1"}, toujours=True))


# --- Le texte du bloc 2 -------------------------------------------------------------

NOUVEAUX = ["aprovechar", "madrugar", "sendero", "mochila", "cumbre", "agotado"]
CONNUS = ["el", "la", "de", "y", "a", "en", "un", "una", "por", "fui", "con", "mi", "amigo",
          "hacía", "frío", "cuando", "llegamos", "era", "tarde", "comimos", "muy", "nos", "la"]


def demande(**champs) -> InputRequest:
    return InputRequest(**{"level": "A2", "theme": "una excursión a la montaña",
                           "objective": OBJ_031, "known_lemmas": CONNUS,
                           "new_lemmas": NOUVEAUX, "target_words": 30, **champs})


def redaction(texte: str) -> Redaction:
    """Le texte, une phrase par point."""
    phrases = re.split(r"(?<=\.) ", texte)
    return Redaction(sentences=[Phrase(es=p, fr=f"fr {i}") for i, p in enumerate(phrases)])


class Reperer:
    """Un faux juge pour les phrases de l'objectif : `emploie` pour les numéros donnés, et
    un numéro hors du texte en plus."""

    def __init__(self, *numeros: int, eteint: bool = False):
        self.numeros = numeros
        self.eteint = eteint
        self.appels: list[list[dict]] = []

    def __call__(self, messages, modele):
        assert modele is Reperage
        self.appels.append(messages)
        if self.eteint:
            raise LLMIndisponible("Mistral ne répond pas.")
        n = len(messages[1]["content"].splitlines())
        return Reperage(phrases=[PhraseJugee(numero=i, analyse_courte="?", emploie=i in self.numeros)
                                 for i in [*range(1, n + 1), 99]])


# 30 mots, tous connus ou nouveaux.
SIMPLE = ("Fui a la cumbre con mi amigo y una mochila. Hacía frío cuando llegamos. "
          "Era tarde y nos aprovechar el sendero. Comimos muy agotado en la cumbre "
          "con mi amigo.")
# 30 mots, dont 6 inconnus (« tarta », « queso », « bosque »… : 80 % de couverture).
DIFFICILE = ("Fui a la cumbre con mi amigo y una tarta. Hacía frío cuando llegamos al bosque. "
             "Era tarde y nos queso el sendero. Comimos muy niebla en la cumbre hondo vereda.")


class Redacteur:
    """Rend les versions préparées, dans l'ordre, et note les demandes."""

    def __init__(self, *versions):
        self.versions = list(versions)
        self.appels: list[list[dict]] = []

    def __call__(self, messages, modele):
        assert modele is Redaction
        self.appels.append(messages)
        version = self.versions.pop(0)
        if isinstance(version, Exception):
            raise version
        return version


def test_un_texte_assez_connu_est_garde_tel_quel():
    r, juge = Redacteur(redaction(SIMPLE)), Reperer(2)
    texte = generer(demande(), r, FausseLangue(), juge)
    assert texte.attempts == 1 and texte.coverage == 1.0
    assert texte.text == SIMPLE
    assert texte.sentences[0].fr == "fr 0"
    # Le juge repère les phrases de l'objectif, numérotées à partir de 1 ; places à partir de 0.
    assert texte.objective_hits == [1]
    assert juge.appels[0][1]["content"].startswith("1. Fui a la cumbre")
    assert "Combinaison réussie" in juge.appels[0][0]["content"]
    assert texte.unknown_lemmas == []
    assert texte.new_used == ["aprovechar", "sendero", "mochila", "cumbre", "agotado"]
    consigne = r.appels[0][0]["content"]
    assert "nivel A2" in consigne and "una excursión a la montaña" in consigne
    assert "aprovechar, madrugar" in consigne and "Dormía cuando sonó" in consigne
    assert "Unas 30 palabras en total, en unas 3 frases" in consigne
    # Le critère de l'objectif, pour que l'IA l'emploie vraiment.
    assert "Combinaison réussie" in consigne
    # Les lemmes connus n'entrent jamais dans la consigne.
    assert "amigo" not in consigne


def test_sous_92_le_texte_est_reecrit_et_le_meilleur_garde():
    r = Redacteur(redaction(DIFFICILE), redaction(SIMPLE))
    texte = generer(demande(), r, FausseLangue(), Reperer())
    assert texte.attempts == 2 and texte.text == SIMPLE
    reecrire = r.appels[1]
    assert "tarta" in reecrire[0]["content"] and "aprovechar" in reecrire[0]["content"]
    # Le texte à réécrire, une phrase par ligne.
    assert reecrire[1]["content"] == "\n".join(p.es for p in redaction(DIFFICILE).sentences)


def test_au_dessus_de_92_pas_de_reecriture():
    # Un mot inconnu sur 30 : 96,7 %.
    presque = SIMPLE.replace("frío", "granizo")
    texte = generer(demande(), Redacteur(redaction(presque)), FausseLangue(), Reperer())
    assert texte.attempts == 1 and texte.unknown_lemmas == ["granizo"]


def test_une_fois_reecrit_le_texte_vise_95():
    # 93,3 % : au-dessus du seuil, mais une réécriture vise 95 %.
    deux = SIMPLE.replace("frío", "granizo").replace("tarde", "bruma")
    moins = DIFFICILE
    r = Redacteur(redaction(moins), redaction(deux), redaction(SIMPLE))
    texte = generer(demande(), r, FausseLangue(), Reperer())
    assert texte.attempts == 3 and texte.coverage == 1.0


def test_une_version_trop_courte_ou_trop_longue_est_ecartee():
    r = Redacteur(redaction(DIFFICILE), redaction("Fui con mi amigo."),
                  redaction(" ".join([SIMPLE] * 2)))
    texte = generer(demande(), r, FausseLangue(), Reperer())
    assert texte.attempts == 3 and texte.text == DIFFICILE


def test_si_l_ia_tombe_en_reecrivant_la_meilleure_version_sert():
    r = Redacteur(redaction(DIFFICILE), LLMIndisponible("Ollama ?"))
    texte = generer(demande(), r, FausseLangue(), Reperer())
    assert texte.text == DIFFICILE and texte.attempts == 2


def test_un_texte_vide_est_une_erreur():
    with pytest.raises(LLMIndisponible):
        generer(demande(), Redacteur(redaction("  ")), FausseLangue(), Reperer())


def test_le_juge_muet_ne_perd_pas_le_texte():
    texte = generer(demande(), Redacteur(redaction(SIMPLE)), FausseLangue(), Reperer(eteint=True))
    assert texte.text == SIMPLE and texte.objective_hits is None


def test_reperer_ecarte_les_numeros_hors_texte():
    assert reperer(demande().objective, redaction(SIMPLE), Reperer(1, 99)) == [0]


def test_la_longueur_se_demande_aussi_en_phrases():
    r = Redacteur(redaction(SIMPLE))
    generer(demande(target_words=150), r, FausseLangue(), Reperer())
    assert "Unas 150 palabras en total, en unas 12 frases" in r.appels[0][0]["content"]


def test_presents_par_lemme_ou_par_forme():
    langue = FausseLangue({"madrugamos": "madrugar"})
    assert presents(["madrugar", "cumbre", "sendero"], langue, "Madrugamos hacia la cumbre") == [
        "madrugar", "cumbre"]


def test_six_a_huit_mots_nouveaux():
    with pytest.raises(ValueError):
        demande(new_lemmas=NOUVEAUX[:5])
    with pytest.raises(ValueError):
        demande(new_lemmas=NOUVEAUX + ["a", "b", "c"])


# --- Les routes ---------------------------------------------------------------------

class FauxSeance(Faux):
    def __init__(self):
        super().__init__()
        self.redactions: list = []
        self.juge = Juge("correct_not_shown")
        self.reperer = Reperer()
        self.dits: list[str] = []

    def structurer(self, messages, modele):
        if modele is Jugements:
            return self.juge(messages, modele)
        if modele is Reperage:
            return self.reperer(messages, modele)
        return super().structurer(messages, modele)

    def rediger(self, messages, modele):
        version = self.redactions.pop(0)
        if isinstance(version, Exception):
            raise version
        return version

    def dire(self, texte):
        self.dits.append(texte)
        return super().dire(texte)


@pytest.fixture
def faux():
    return FauxSeance()


def client(faux, langue=True):
    return TestClient(main.create_app(moteurs=faux, charger=False,
                                      langue=FausseLangue() if langue else None))


def test_route_placement(faux):
    corps = {"level": "A2", "items": [{**PC_001, "answer": "Buenas tardes, ¿qué hay?"},
                                      {**PC_001, "objective_id": "obj_002", "answer": "¡Buenas tardes! ¿Qué tal?"}]}
    reponse = client(faux).post("/placement/evaluate", json=corps)
    assert reponse.status_code == 200
    assert reponse.json() == [
        {"objective_id": "obj_001", "verdict": "correct_not_shown", "analyse_courte": "Pourquoi."},
        {"objective_id": "obj_002", "verdict": "shown", "analyse_courte": DEJA_ATTENDUE}]


def test_route_placement_l_instruction_est_optionnelle(faux):
    sans = {k: v for k, v in PC_001.items() if k != "instruction"}
    reponse = client(faux).post("/placement/evaluate", json={"items": [{**sans, "answer": "x"}]})
    assert reponse.status_code == 200


def test_route_placement_juge_muet_503(faux):
    faux.juge = Juge(oublier={"respuesta"}, toujours=True)
    reponse = client(faux).post("/placement/evaluate",
                                json={"items": [{**PC_001, "answer": "respuesta"}]})
    assert reponse.status_code == 503


def test_route_placement_sans_defi_422(faux):
    assert client(faux).post("/placement/evaluate", json={"items": []}).status_code == 422


def test_route_texte(faux):
    faux.redactions = [redaction(DIFFICILE), redaction(SIMPLE)]
    faux.reperer = Reperer(1, 3)
    corps = demande().model_dump()
    reponse = client(faux).post("/session/generate-input", json=corps)
    assert reponse.status_code == 200
    texte = reponse.json()
    assert texte["text"] == SIMPLE and texte["attempts"] == 2
    assert texte["objective_hits"] == [0, 2]
    assert set(texte) == {"text", "sentences", "coverage", "unknown_lemmas", "new_used",
                          "objective_hits", "attempts"}


def test_route_texte_sans_langue_503(faux):
    reponse = client(faux, langue=False).post("/session/generate-input", json=demande().model_dump())
    assert reponse.status_code == 503


def test_route_texte_ia_eteinte_503(faux):
    faux.redactions = [LLMIndisponible("Ollama est-il lancé sur le PC ?")]
    reponse = client(faux).post("/session/generate-input", json=demande().model_dump())
    assert reponse.status_code == 503 and "Ollama" in reponse.json()["detail"]


def test_route_tts_un_audio_par_phrase(faux):
    reponse = client(faux).post("/tts", json={"sentences": ["Hola.", " ¿Qué tal? "]})
    assert reponse.status_code == 200
    audios = reponse.json()["audios"]
    assert [a["text"] for a in audios] == ["Hola.", "¿Qué tal?"]
    assert [base64.b64decode(a["audio"]).decode() for a in audios] == ["m4a:Hola.", "m4a:¿Qué tal?"]
    assert faux.dits == ["Hola.", "¿Qué tal?"]


def test_route_tts_limites(faux):
    c = client(faux)
    assert c.post("/tts", json={"sentences": []}).status_code == 422
    assert c.post("/tts", json={"sentences": ["Hola.", "  "]}).status_code == 422
    assert c.post("/tts", json={"sentences": ["Hola."] * 41}).status_code == 422
    assert faux.dits == []
