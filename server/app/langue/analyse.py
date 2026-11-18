"""spaCy, `es_core_news_lg` : le même modèle que celui qui a fait le lexique de l'app
(`scripts/build_lexicon.py`), pour que les lemmes trouvés ici soient ceux de ses clés.

Le modèle est installé par `uv sync` (une wheel, voir `pyproject.toml`). Il tourne
sur le processeur, sans toucher à la carte graphique.

spaCy rate l'impératif à pronom collé : « dímelo » donne « dímelir », « cuéntame »
reste « cuéntame », « Cómpralo » en tête de phrase passe pour un nom propre. Il rate
aussi les impératifs irréguliers courts (« ven », « haz »). `reparer` reprend ces
mots-là, et eux seuls : ceux où spaCy a visiblement échoué (`rate`). Une réparation
n'est gardée que si le verbe trouvé existe dans le vocabulaire du modèle.

Il rate enfin la deuxième personne du singulier, rare dans ses textes d'entraînement
et partout dans une conversation : « hiciste », « hacías », « cuentes » restent tels
quels, « pasaste » devient « pasastar », « escondías » passe pour un nom. La même
forme à la troisième personne (« hizo », « hacía », « pasó », « cuente »), il la
lemmatise sans faute : `troisieme_personne` la fabrique (essai du 2026-11-18).
"""

from __future__ import annotations

import re
import unicodedata

from . import Langue, Mot

MODELE = "es_core_news_lg"

# Ce qui ne se compte pas dans la couverture : un chiffre ou une virgule ne disent rien
# du vocabulaire de l'apprenant. Les noms propres non plus, mais spaCy en voit à tort
# (`rate`) : ils sont écartés après la tentative de réparation.
NON_MOTS = {"NUM", "PUNCT", "SYM", "SPACE"}

# Un ou deux pronoms collés au verbe : « cómpra|lo », « dí|me|lo », « siénta|te ». À deux,
# l'ordre est fixe (« me lo », « se la ») : « levánte|se » n'est pas « levan|te|se ».
DATIFS = r"me|te|se|nos|os"
OBJETS = r"lo|la|los|las|le|les"
ENCLITIQUES = re.compile(
    rf"^(?P<verbe>.{{2,}}?)(?P<pronoms>(?:{DATIFS})(?:{OBJETS})|{DATIFS}|{OBJETS})$")

# Les impératifs que spaCy ne ramène pas à leur verbe, tutoiement et vouvoiement.
IRREGULIERS = {
    "di": "decir", "diga": "decir", "digan": "decir",
    "haz": "hacer", "haga": "hacer", "hagan": "hacer",
    "pon": "poner", "ponga": "poner", "pongan": "poner",
    "ven": "venir", "venga": "venir", "vengan": "venir",
    "sal": "salir", "salga": "salir", "salgan": "salir",
    "ten": "tener", "tenga": "tener", "tengan": "tener",
    "ve": "ir", "vaya": "ir", "vayan": "ir", "vamos": "ir", "vámonos": "ir",
    "sé": "ser", "sea": "ser", "sean": "ser",
    "da": "dar", "dé": "dar", "den": "dar",
    "oye": "oír", "oiga": "oír", "oigan": "oír",
    "trae": "traer", "traiga": "traer", "traigan": "traer",
}

# Les impératifs d'une syllabe : les seuls qui prennent un pronom sans accent écrit
# (« dame », « hazlo », « vete »), avec l'infinitif (« hacerlo »).
MONOSYLLABES = {"di", "haz", "pon", "ven", "sal", "ten", "ve", "da"}

INFINITIF = re.compile(r"^[a-zñü]*(?:ar|er|ir|ír)$")  # « ir » compris

# Le passé simple de « tú » dont la 3e personne ne se déduit pas de la terminaison.
TU_IRREGULIERS = {"fuiste": "fue", "diste": "dio", "viste": "vio"}

# Un pronom devant un mot pris pour un nom : « te escondías » est un verbe.
CLITIQUES = {"me", "te", "se", "nos", "os", "lo", "la", "le", "los", "las", "les"}


def troisieme_personne(forme: str) -> list[str]:
    """La même forme à la 3e personne, si `forme` peut être une 2e personne du
    singulier ; plusieurs essais quand la terminaison ne suffit pas à trancher.
    « hiciste » : « hició » (régulier), puis « hizo » ; « seguiste » : « siguió »."""
    if forme in TU_IRREGULIERS:
        return [TU_IRREGULIERS[forme]]
    if forme.endswith("íste"):                       # leíste → leyó
        return [forme[:-4] + "yó"]
    if forme.endswith("aste"):                       # pasaste → pasó
        return [forme[:-4] + "ó"]
    if forme.endswith("iste"):
        radical = forme[:-4]
        fort = radical[:-1] + "z" if radical.endswith("c") else radical
        candidats = [radical + "ió", inflechir(radical) + "ió", fort + "o"]
        return list(dict.fromkeys(candidats))       # comiste, seguiste, hiciste / pusiste
    if forme.endswith("s") and len(forme) > 3:     # hacías, hablabas, cuentes, harás
        return [forme[:-1]]
    return []


def inflechir(radical: str) -> str:
    """La voyelle du radical qui change au passé simple des verbes en -ir : e → i,
    o → u (« segu » → « sigu », « dorm » → « durm »)."""
    for i in range(len(radical) - 1, -1, -1):
        if radical[i] in "eo":
            return radical[:i] + ("i" if radical[i] == "e" else "u") + radical[i + 1:]
    return radical


def sans_accent(mot: str) -> str:
    """L'accent écrit qu'ajoute le pronom collé (« cómpra-lo ») s'en va ; ñ et ü restent."""
    decompose = unicodedata.normalize("NFD", mot).replace("\u0301", "")
    return unicodedata.normalize("NFC", decompose)


def lemme_utile(lemme: str, pos: str) -> str:
    """spaCy rend « hacer él » pour « hacerlo » : le lemme est le verbe. Même règle
    que dans `build_lexicon.py`."""
    if " " in lemme and pos in ("VERB", "AUX"):
        return lemme.split(" ")[0]
    return lemme


def rate(token, connu) -> bool:
    """spaCy a-t-il échoué sur ce mot ? `connu(lemme)` : le modèle a-t-il ce mot dans
    son vocabulaire (un vecteur) ? Les infinitifs qu'il invente (« dímelir », « vetir »)
    n'en ont pas.

    - un verbe dont le lemme n'est pas un infinitif (« cuéntame » laissé tel quel,
      « dímelo » → « di ») ou est un infinitif inventé (« dímelir ») ;
    - un mot accentué qui finit par un pronom, laissé tel quel ou mal lemmatisé
      (« dáselo » pris pour un nom, « vámonos » → « vámono ») ;
    - un nom propre en tête de phrase (« Cómpralo », « Come »), ou sans majuscule
      (« ponte »). Au milieu d'une phrase, la majuscule ne trompe pas. Après « ¿ » ou
      « ¡ », on est encore en tête (« ¿Seguiste en bici? ») ;
    - un nom ou un adjectif juste après un pronom (« te escondías »)."""
    forme = token.text.lower()
    lemme = lemme_utile(token.lemma_.lower(), token.pos_)
    if token.pos_ == "PROPN":
        return en_tete(token) or token.text[0].islower()
    if token.pos_ in ("VERB", "AUX"):
        return not INFINITIF.match(lemme) or not connu(lemme)
    if token.pos_ in ("NOUN", "ADJ") and token.i > 0:
        avant = token.doc[token.i - 1]
        if avant.pos_ == "PRON" and avant.text.lower() in CLITIQUES:
            return True
    return ((lemme == forme or not connu(lemme)) and forme != sans_accent(forme)
            and ENCLITIQUES.match(forme) is not None)


def en_tete(token) -> bool:
    """Le premier mot de sa phrase, la ponctuation d'ouverture (« ¿ », « ¡ ») mise à part."""
    return all(t.is_punct for t in token.doc[token.sent.start:token.i])


def colle(forme: str, coupe: re.Match) -> bool:
    """Ce découpage est-il un verbe et ses pronoms ? Sans accent écrit, seulement
    après un impératif d'une syllabe ou un infinitif : sinon « dios » serait
    « di|os », « vale » « va|le », « este » « es|te ». « os » ne suit jamais un
    impératif d'une syllabe."""
    if forme != sans_accent(forme):
        return True
    verbe = coupe["verbe"]
    if INFINITIF.match(verbe):
        return True
    return verbe in MONOSYLLABES and not coupe["pronoms"].startswith("os")


def compte(token) -> bool:
    if token.pos_ in NON_MOTS or token.like_num:
        return False
    # Un tiret, un emoji, des points de suspension mal étiquetés : rien d'une lettre.
    return any(c.isalpha() for c in token.text)


class Spacy(Langue):
    def __init__(self, modele: str = MODELE):
        import spacy

        # Le parseur et les entités nommées ne servent pas : l'étiquette de chaque mot
        # (et donc PROPN) et son lemme viennent du tagger, du morphologiseur et du
        # lemmatiseur. Le découpage en phrases (`is_sent_start`) vient du senter.
        self.nlp = spacy.load(modele, disable=["parser", "ner"])
        self.nlp.enable_pipe("senter")
        self.nom = modele

    def reparer(self, forme: str) -> str | None:
        """Le verbe d'un impératif raté, ou None si ce n'en est pas un. Les pronoms
        collés sont détachés et remis devant le verbe, avec un sujet : spaCy relit
        « él lo compra » sans hésiter, quand « compra lo » reste pour lui un nom.
        Sans pronom, le mot est relu de même : « Come » en tête de phrase, pris pour
        un nom propre, redevient « él come »."""
        if (irregulier := IRREGULIERS.get(forme)) is not None:
            return irregulier
        if (coupe := ENCLITIQUES.match(forme)) is not None and colle(forme, coupe):
            verbe = sans_accent(coupe["verbe"])
            if verbe in IRREGULIERS:
                return IRREGULIERS[verbe]
            pronoms = re.findall(rf"{DATIFS}|{OBJETS}", coupe["pronoms"])
            if (lemme := self.verbe(["él", *pronoms, verbe])) is not None:
                return lemme
        if (lemme := self.verbe(["él", forme])) is not None:
            return lemme
        for candidat in troisieme_personne(forme):
            if (lemme := self.verbe(["él", candidat])) is not None:
                return lemme
        return None

    def connu(self, mot: str) -> bool:
        return self.nlp.vocab.has_vector(mot)

    def verbe(self, mots: list[str]) -> str | None:
        """L'infinitif du dernier mot, si spaCy y voit un verbe qui existe : relu seul,
        « Adela » donnerait « adelar »."""
        tete = self.nlp(" ".join(mots))[-1]
        lemme = lemme_utile(tete.lemma_.lower(), tete.pos_)
        if tete.pos_ in ("VERB", "AUX") and INFINITIF.match(lemme) and self.connu(lemme):
            return lemme
        return None

    def mots(self, texte: str) -> list[Mot]:
        mots = []
        for t in self.nlp(texte):
            if not compte(t):
                continue
            forme = t.text.lower()
            lemme = self.reparer(forme) if rate(t, self.connu) else None
            if lemme is None:
                if t.pos_ == "PROPN":
                    continue
                lemme = lemme_utile(t.lemma_.lower(), t.pos_)
            mots.append(Mot(forme=forme, lemme=lemme))
        return mots


def installe(modele: str = MODELE) -> bool:
    """Le modèle est-il là ? Sans le charger : les tests s'en servent pour se sauter."""
    try:
        import spacy.util
    except ImportError:
        return False
    return spacy.util.is_package(modele)
