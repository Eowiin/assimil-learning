"""La langue : la couverture, avec un faux découpage (partout), et les lemmes du vrai
spaCy (sautés si `es_core_news_lg` n'est pas installé)."""

import pytest

from app.langue import Couverture, Langue, Mot, couvrir
from app.langue.analyse import ENCLITIQUES, installe, lemme_utile, sans_accent


class Faux(Langue):
    """Un mot par espace, et un lemme par table : de quoi tester la mesure seule."""
    nom = "faux"

    def __init__(self, lemmes: dict[str, str]):
        self.lemmes = lemmes

    def mots(self, texte):
        return [Mot(forme=f, lemme=self.lemmes.get(f, f)) for f in texte.lower().split()]


# --- La couverture -------------------------------------------------------------------

def test_couverture_compte_chaque_occurrence():
    faux = Faux({"tengo": "tener", "tiene": "tener"})
    c = faux.couverture("tengo un perro y tiene un gato", {"tener", "un", "y"})
    assert c == Couverture(taux=5 / 7, inconnus=["perro", "gato"], mots=7)


def test_couverture_inconnus_une_fois_dans_l_ordre():
    c = couvrir([Mot("gato", "gato"), Mot("perro", "perro"), Mot("gatos", "gato")], set())
    assert c.inconnus == ["gato", "perro"]
    assert c.taux == 0


def test_couverture_par_la_forme_si_le_lemme_manque():
    # spaCy peut se tromper de lemme sur un mot que l'apprenant connaît : la forme suffit.
    c = couvrir([Mot("vino", "venir")], {"vino"})
    assert c.taux == 1 and c.inconnus == []


def test_couverture_ignore_la_casse_des_connus():
    assert couvrir([Mot("hola", "hola")], {"Hola"}).taux == 1


def test_couverture_d_un_texte_vide():
    assert couvrir([], {"hola"}) == Couverture(taux=1.0, inconnus=[], mots=0)


def test_lemmatiser():
    assert Faux({"quiero": "querer"}).lemmatiser("Quiero pan") == ["querer", "pan"]


# --- Les règles, sans le modèle ----------------------------------------------------------

def test_lemme_du_pronom_colle():
    assert lemme_utile("hacer él", "VERB") == "hacer"
    assert lemme_utile("de el", "ADP") == "de el"


def test_sans_accent_garde_la_tilde():
    assert sans_accent("cómpralo") == "compralo"
    assert sans_accent("añádelo") == "añadelo"


@pytest.mark.parametrize("forme, verbe, pronoms", [
    ("dímelo", "dí", "melo"),
    ("cómpralo", "cómpra", "lo"),
    ("levántese", "levánte", "se"),   # pas « levan|te|se » : l'ordre est fixe
    ("siéntate", "siénta", "te"),
])
def test_pronoms_colles(forme, verbe, pronoms):
    coupe = ENCLITIQUES.match(forme)
    assert (coupe["verbe"], coupe["pronoms"]) == (verbe, pronoms)


# --- Le vrai spaCy -----------------------------------------------------------------------

@pytest.fixture(scope="module")
def spacy_es():
    if not installe():
        pytest.skip("es_core_news_lg n'est pas installé")
    from app.langue.analyse import Spacy
    return Spacy()


def lemmes(langue, texte):
    return langue.lemmatiser(texte)


def test_pronom_colle_ramene_au_verbe(spacy_es):
    assert "hacer" in lemmes(spacy_es, "Quiero hacerlo mañana.")
    assert "comprar" in lemmes(spacy_es, "Voy a comprárselo.")


@pytest.mark.parametrize("phrase, verbe", [
    ("Cómpralo mañana.", "comprar"),
    ("Dímelo ya.", "decir"),
    ("Cuéntame algo.", "contar"),
    ("Siéntate aquí.", "sentar"),
    ("Levántese temprano.", "levantar"),
    ("Dáselo a ella.", "dar"),
    ("Ven aquí.", "venir"),
    ("Vete ya.", "ir"),
    ("Come y bebe.", "comer"),
])
def test_imperatifs(spacy_es, phrase, verbe):
    assert lemmes(spacy_es, phrase)[0] == verbe


def test_imperatif_en_milieu_de_phrase(spacy_es):
    assert lemmes(spacy_es, "Cómpralo mañana y dímelo.") == ["comprar", "mañana", "y", "decir"]
    assert lemmes(spacy_es, "Dámelo, ponte el abrigo y vete.") == ["dar", "poner", "el", "abrigo", "y", "ir"]


def test_ecarte_noms_propres_nombres_ponctuation(spacy_es):
    assert lemmes(spacy_es, "María tiene 3 hermanos y 12,5 euros.") == ["tener", "hermano", "y", "euros"]
    assert lemmes(spacy_es, "Ana y Pedro viven en Sevilla.") == ["y", "vivir", "en"]


def test_un_prenom_ne_devient_pas_un_verbe(spacy_es):
    assert lemmes(spacy_es, "Adela habla.") == ["hablar"]


def test_les_mots_accentues_restent_des_noms(spacy_es):
    assert lemmes(spacy_es, "Vi una película con los teléfonos.") == [
        "ver", "uno", "película", "con", "el", "teléfono"]


def test_le_contexte_decide_du_lemme(spacy_es):
    # « vino » : venir, puis le vin. Toujours la phrase entière.
    assert lemmes(spacy_es, "Vino tarde y bebió vino.") == ["venir", "tarde", "y", "beber", "vino"]


def test_couverture_reelle(spacy_es):
    c = spacy_es.couverture("Mi madre compró pan en Madrid.", {"mi", "madre", "comprar", "en"})
    assert c.inconnus == ["pan"]
    assert c.taux == pytest.approx(4 / 5)
