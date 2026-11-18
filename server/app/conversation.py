"""La conversation : les consignes données à l'IA, et la forme des échanges.

Rien ici ne charge de modèle : les modèles sont dans `moteurs.py`, derrière
l'interface `Moteurs`, que les tests remplacent par un faux. La mesure d'une réplique
passe par une `Langue` (spaCy), que les tests remplacent aussi.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Callable, Iterable
from typing import Literal, Protocol, TypeVar

from pydantic import BaseModel, Field

from .langue import Langue
from .llm import LLMIndisponible

M = TypeVar("M", bound=BaseModel)

Niveau = Literal["A0", "A1", "A2", "B1", "B2", "C1", "C2"]
Mode = Literal["roleplay", "speed"]

# Sans niveau, la conversation d'avant le moteur adaptatif : l'app actuelle n'en envoie pas.
NIVEAU_PAR_DEFAUT = "A2-B1"

CONSIGNE_MODELE = """Eres un compañero de conversación para un estudiante francés de español \
(nivel {niveau}, español de España). Habláis de forma natural, como dos amigos.

Reglas:
- Responde siempre en español de España, en {longueur}.
- Reacciona primero a lo que acaba de decir el estudiante, como haría un amigo que escucha.
- Si dice que no conoce o no entiende una palabra, explícasela con palabras sencillas antes de seguir.
- {style}
- Termina siempre con una pregunta para que la conversación siga.
- No corrijas los errores del estudiante durante la conversación: responde a lo que quiso decir.
- Nada de listas, emojis, asteriscos ni formato: tu respuesta se leerá en voz alta."""

LONGUEUR = "1 a 3 frases cortas"
LONGUEUR_RAPIDE = "1 o 2 frases cortas como máximo"

STYLE = "Usa un vocabulario sencillo y frases claras."
# Le vocabulaire se règle par la mesure (`allowed_lemmas`) ; la consigne ne donne que le ton.
STYLES: dict[str, str] = {
    "A0": "Usa frases muy cortas, de 8 palabras como máximo, y solo palabras muy corrientes.",
    "A1": "Usa frases cortas y palabras muy corrientes, en presente sobre todo.",
    "A2": STYLE,
    "B1": STYLE,
    "B2": "Usa un vocabulario corriente y natural, sin simplificar de más.",
    "C1": "Habla con naturalidad, como con un nativo, con alguna expresión idiomática.",
    "C2": "Habla con naturalidad, como con un nativo, con alguna expresión idiomática.",
}

CONSIGNE = CONSIGNE_MODELE.format(niveau=NIVEAU_PAR_DEFAUT, longueur=LONGUEUR, style=STYLE)

# Une consigne de tour, pas un message de l'apprenant : elle n'entre pas dans
# l'historique que l'app garde.
OUVERTURE = ("(Empieza tú la conversación: saluda al estudiante y propón un tema de la vida "
             "cotidiana con una pregunta sencilla.)")
OUVERTURE_SUJET = ("(Empieza tú la conversación: saluda al estudiante y propón hablar de este "
                   "tema, con una pregunta sencilla: {sujet})")
OUVERTURE_ROLEPLAY = ("(Empieza tú: abre la escena del escenario con una primera réplica corta, "
                      "ya en tu papel, que termine con una pregunta.)")
OUVERTURE_RAPIDE = ("(Empieza tú: saluda en pocas palabras y lanza enseguida la primera pregunta "
                    "directa{sujet}.)")


class Objectif(BaseModel):
    """Un micro-objectif, tel que `Resources/curriculum/es/objectives.json` le décrit.
    L'app l'envoie en entier : le serveur n'a pas de copie du référentiel."""
    id: str
    titre: str
    regle: str
    prompt_ia: str = ""
    validation: str = ""


class Profil(BaseModel):
    """Ce que l'iPhone sait de l'apprenant, joint à la conversation
    (`docs/module-profil.md`, étape 3 ; `docs/moteur-adaptatif.md`). Le serveur ne le
    garde pas. Tout est optionnel : l'app d'aujourd'hui n'envoie que `watch` et `words`."""
    # La faute qui revient le plus, telle que l'IA l'a nommée au récapitulatif.
    watch: str | None = None
    # Des mots compris en révision, pas encore sus dans l'autre sens.
    words: list[str] = Field(default_factory=list)
    level: Niveau | None = None
    # L'objectif du jour. Sans `mode`, il est amené comme `watch`.
    objective: Objectif | None = None
    # `roleplay` : le `prompt_ia` de l'objectif sert de scénario. `speed` : des questions
    # directes en rafale. Absent : la conversation libre.
    mode: Mode | None = None
    # Les lemmes que l'apprenant connaît. Ils ne servent qu'à mesurer la réplique, jamais
    # dans la consigne : une liste de 800 mots noierait un modèle de 8B.
    allowed_lemmas: list[str] = Field(default_factory=list)


# Une consigne courte garde Qwen3 8B rapide et concentré.
MOTS_AU_PLUS = 5
# Le point qui revient : à l'ouverture, puis une réplique sur trois. À chaque tour,
# la conversation ne parle plus que de lui.
POINT_TOUS_LES = 3


def consigne(profil: Profil | None = None) -> str:
    """La consigne de conversation, avec le profil quand l'app en envoie un."""
    if profil is None:
        return CONSIGNE
    rapide = profil.mode == "speed"
    texte = CONSIGNE_MODELE.format(niveau=profil.level or NIVEAU_PAR_DEFAUT,
                                   longueur=LONGUEUR_RAPIDE if rapide else LONGUEUR,
                                   style=STYLES.get(profil.level or "", STYLE))
    lignes = []
    objectif = profil.objective
    if _scenario(profil):
        lignes.append("- Juego de rol. Este es el escenario, escrito en francés solo para ti: «"
                      + objectif.prompt_ia.strip() + "». Interpreta tu papel de principio a fin, "
                      "sin salir de la escena.")
    if rapide:
        lignes.append("- Ronda rápida: reacciona en pocas palabras y lanza enseguida otra pregunta "
                      "directa y corta, una tras otra, como en un juego de preguntas.")
        if objectif:
            lignes.append("- Tus preguntas deben llevar al estudiante a usar este punto: «"
                          + _point(objectif) + "». Nunca lo nombres, nunca ofrezcas opciones y no "
                          "le corrijas.")
    elif objectif and not _scenario(profil):
        lignes.append("- El objetivo de hoy es este punto: «" + _point(objectif) + "». De vez en "
                      "cuando, haz preguntas normales cuya respuesta lo necesite. Nunca lo nombres, "
                      "nunca ofrezcas opciones y no le corrijas.")
    if mots := _mots(profil):
        lignes.append("- El estudiante está aprendiendo estas palabras: " + ", ".join(mots)
                      + ". Úsalas en tus respuestas, una por respuesta, para que las oiga y se "
                      "anime a usarlas.")
    if surveiller := _surveiller(profil):
        lignes.append("- El estudiante suele equivocarse en este punto: «" + surveiller
                      + "». De vez en cuando, haz preguntas normales cuya respuesta lo necesite. "
                      "Nunca nombres el punto, nunca ofrezcas opciones como «eres o estás», y no "
                      "le corrijas.")
    return texte + ("\n" + "\n".join(lignes) if lignes else "")


def _point(objectif: Objectif) -> str:
    """L'objectif tel que l'IA doit l'amener : son titre et sa règle (en français, avec
    des exemples en espagnol)."""
    return f"{objectif.titre.strip()} : {objectif.regle.strip()}"


def _scenario(profil: Profil | None) -> bool:
    return bool(profil and profil.mode == "roleplay" and profil.objective
                and profil.objective.prompt_ia.strip())


def _mots(profil: Profil | None) -> list[str]:
    return [m.strip() for m in profil.words if m.strip()][:MOTS_AU_PLUS] if profil else []


def _surveiller(profil: Profil | None) -> str | None:
    return profil.watch.strip() if profil and profil.watch and profil.watch.strip() else None


def _points(profil: Profil | None) -> list[str]:
    """Ce que la note du tour fait amener, une réplique sur trois, à tour de rôle :
    l'objectif (en conversation libre) puis la faute qui revient. En jeu de rôle, le
    scénario amène déjà l'objectif."""
    if profil is None:
        return []
    objectif = (profil.objective.titre.strip()
                if profil.objective and profil.mode != "speed" and not _scenario(profil) else None)
    return [p for p in (objectif, _surveiller(profil)) if p]


def note_du_tour(profil: Profil | None, rang: int, ouverture: bool = False) -> str | None:
    """La consigne précise d'une réplique, collée au message auquel l'IA répond. Un
    modèle de 8B suit mal une règle donnée en tête de conversation ; il suit bien
    une demande récente et précise : un seul mot, et une question qui oblige à
    employer le point. `rang` : le nombre de répliques déjà faites par l'IA, qui
    fait tourner les mots. La note n'entre pas dans l'historique que l'app garde."""
    demandes = []
    if mots := _mots(profil):
        demandes.append(f"usa la palabra «{mots[rang % len(mots)]}» si encaja sin forzar")
    rapide = profil is not None and profil.mode == "speed"
    if rapide:
        # Chaque question appelle l'objectif : c'est tout l'exercice.
        cible = (f" cuya respuesta lleve al estudiante a usar «{profil.objective.titre.strip()}»"
                 if profil.objective else "")
        demandes.append(f"haz una sola pregunta directa y corta{cible}, sin ofrecer opciones ni "
                        "nombrar el punto")
    elif (points := _points(profil)) and rang % POINT_TOUS_LES == 0:
        point = points[(rang // POINT_TOUS_LES) % len(points)]
        demandes.append(f"termina con una pregunta normal y natural, sin ofrecer opciones ni "
                        f"nombrar el punto, cuya respuesta lleve al estudiante a usar «{point}»")
    if not demandes:
        return None
    # D'abord répondre à ce qu'il vient de dire : sans ça, le modèle ne fait plus
    # que ce que la note demande.
    if ouverture:
        return "(En esta primera réplica, " + ", y ".join(demandes) + ".)"
    debut = ("reacciona en pocas palabras a lo que acaba de decir" if rapide
             else "primero responde de verdad a lo que acaba de decir")
    return (f"(Nota para ti, no la menciones: {debut}. "
            "Después, en la misma respuesta, " + ", y ".join(demandes) + ".)")


class Message(BaseModel):
    """Une réplique de la conversation, telle que l'app la garde."""
    role: Literal["user", "assistant"]
    content: str


class Moteurs(Protocol):
    """Ce que le serveur attend des modèles. `moteurs.Reels` les charge vraiment ;
    les tests en passent un faux."""

    def ecouter(self, audio: bytes, contexte: str | None = None) -> str:
        """La transcription d'un enregistrement (n'importe quel format lu par ffmpeg).
        `contexte` : la dernière réplique de l'IA, que Whisper peut recevoir pour
        mieux reconnaître les mots qu'elle vient d'employer."""
        ...

    def repondre(self, messages: list[dict]) -> str:
        """La réplique suivante de l'IA, consigne comprise dans `messages`."""
        ...

    def structurer(self, messages: list[dict], modele: type[M]) -> M:
        """Une réponse de l'IA dans un format imposé (les corrections, par exemple)."""
        ...

    def dire(self, texte: str) -> bytes:
        """La réplique à voix haute, en AAC (.m4a)."""
        ...


def messages_ouverture(sujet: str | None, profil: Profil | None = None) -> list[dict]:
    sujet = sujet.strip() if sujet and sujet.strip() else None
    if _scenario(profil):
        ouverture = OUVERTURE_ROLEPLAY
    elif profil is not None and profil.mode == "speed":
        ouverture = OUVERTURE_RAPIDE.format(sujet=f", sobre este tema: {sujet}" if sujet else "")
    else:
        ouverture = OUVERTURE_SUJET.format(sujet=sujet) if sujet else OUVERTURE
    if note := note_du_tour(profil, 0, ouverture=True):
        ouverture += "\n" + note
    return [{"role": "system", "content": consigne(profil)}, {"role": "user", "content": ouverture}]


def messages_tour(historique: list[Message], phrase: str, profil: Profil | None = None) -> list[dict]:
    rang = sum(m.role == "assistant" for m in historique)
    note = note_du_tour(profil, rang)
    return ([{"role": "system", "content": consigne(profil)}]
            + [m.model_dump() for m in historique]
            + [{"role": "user", "content": phrase + ("\n\n" + note if note else "")}])


def derniere_replique(historique: list[Message]) -> str | None:
    """Ce que l'IA vient de dire, à quoi l'apprenant répond."""
    return next((m.content for m in reversed(historique) if m.role == "assistant"), None)


# --- La mesure d'une réplique ------------------------------------------------------

# Sous cette part de mots connus, la réplique est réécrite plus simple.
SEUIL_REPLIQUE = 0.85
REECRITURES_AU_PLUS = 2
# Les mots difficiles nommés à l'IA : au-delà, la demande se noie.
INCONNUS_AU_PLUS = 10

CONSIGNE_SIMPLIFIER = """Reescribe esta réplica de una conversación para un estudiante \
francés de español (nivel {niveau}), con palabras más corrientes.

Reglas:
- Estas palabras son demasiado difíciles para él: {inconnus}. Cámbialas por palabras más \
corrientes, o dilo de otra manera.
- Mantén el sentido, el tono y la pregunta final.
- No añadas nada: la misma longitud o más corta.
- Responde solo con la nueva réplica, sin comillas ni comentarios."""


class Mesure(BaseModel):
    """La réplique gardée, sa part de mots connus, et combien de versions l'IA a
    écrites (1 : la première a suffi ; 3 au plus)."""
    texte: str
    couverture: float
    essais: int


def connus_du_tour(profil: Profil, phrase: str | None, langue: Langue) -> set[str]:
    """Les lemmes connus, plus ce que l'apprenant a sous les yeux ou à la bouche : les
    mots qu'il apprend (`words`) et ceux de la phrase qu'il vient de dire. Leurs formes
    comptent aussi, comme dans `couvrir`."""
    connus = {l.lower() for l in profil.allowed_lemmas}
    for texte in [*_mots_appris(profil), phrase or ""]:
        for mot in langue.mots(texte):
            connus.update((mot.lemme, mot.forme))
    return connus


def _mots_appris(profil: Profil) -> list[str]:
    return [m.strip() for m in profil.words if m.strip()]


def messages_simplifier(texte: str, inconnus: list[str], niveau: str | None) -> list[dict]:
    return [{"role": "system",
             "content": CONSIGNE_SIMPLIFIER.format(niveau=niveau or NIVEAU_PAR_DEFAUT,
                                                   inconnus=", ".join(inconnus[:INCONNUS_AU_PLUS]))},
            {"role": "user", "content": texte}]


def _nettoyer(texte: str) -> str:
    """Les guillemets que l'IA met parfois autour de sa réécriture."""
    return texte.strip().strip("«»\"“”'").strip()


def mesurer(premiere: str, repondre: Callable[[list[dict]], str], langue: Langue,
            connus: Iterable[str], niveau: str | None = None) -> Mesure:
    """La réplique telle quelle si l'apprenant en connaît assez de mots ; sinon, l'IA la
    réécrit en recevant les mots inconnus, deux fois au plus, et la meilleure version
    est gardée. Si l'IA tombe pendant une réécriture, la meilleure version déjà écrite
    sert."""
    connus = set(connus)
    meilleure, couverture = premiere, langue.couverture(premiere, connus)
    essais = 1
    while couverture.taux < SEUIL_REPLIQUE and essais <= REECRITURES_AU_PLUS:
        essais += 1
        try:
            texte = _nettoyer(repondre(messages_simplifier(meilleure, couverture.inconnus, niveau)))
        except LLMIndisponible:
            break
        if not texte:
            continue
        nouvelle = langue.couverture(texte, connus)
        if nouvelle.mots and nouvelle.taux > couverture.taux:
            meilleure, couverture = texte, nouvelle
    return Mesure(texte=meilleure, couverture=round(couverture.taux, 3), essais=essais)


def lemmes_produits(phrases: Iterable[str], langue: Langue) -> list[str]:
    """Les lemmes des phrases de l'apprenant, une fois chacun, dans l'ordre. Chaque
    phrase est analysée en entier : le contexte décide du lemme."""
    vus: dict[str, None] = {}
    for phrase in phrases:
        for lemme in langue.lemmatiser(phrase):
            vus.setdefault(lemme)
    return list(vus)


# --- Le récapitulatif --------------------------------------------------------------

CONSIGNE_CORRECTION_MODELE = """Tu es professeur d'espagnol (espagnol d'Espagne). Voici une \
conversation entre un élève francophone (niveau {niveau}) et son partenaire. Les phrases de \
l'élève ont été transcrites depuis sa voix : ignore la ponctuation, les majuscules et les \
accents écrits, qui viennent de la transcription.

La transcription (Whisper) se trompe parfois : un mot qui n'a pas de sens dans la phrase, \
ou qui ne ressemble à rien, vient sans doute d'elle et non de l'élève. Ne le corrige pas, \
et ne relève pas une phrase pour ça.

Relève uniquement les vraies fautes de l'élève : grammaire (accords, conjugaison, \
prépositions, ser/estar…), vocabulaire, ou tournure qu'un Espagnol ne dirait pas. \
Ne relève pas le style, ni une phrase correcte qu'on pourrait dire autrement. \
Une phrase correcte n'a rien à faire dans la liste.

Pour chaque phrase fautive, donne :
- "said" : la phrase de l'élève, telle quelle ;
- "corrected" : la même phrase corrigée, en changeant le moins possible ;
- "explanation" : en français, une phrase courte qui dit la règle ;
- "category" : "grammaire", "vocabulaire" ou "tournure" (une tournure qu'un Espagnol \
ne dirait pas) ;
- "tag" : le point précis, en quelques mots, toujours nommé de la même façon \
(par exemple "ser/estar", "accord du verbe", "por/para", "gustar").

Si l'élève n'a fait aucune faute, renvoie une liste vide."""

CONSIGNE_CORRECTION = CONSIGNE_CORRECTION_MODELE.format(niveau=NIVEAU_PAR_DEFAUT)

CONSIGNE_ECRIT = """Tu es professeur d'espagnol (espagnol d'Espagne). Voici un texte écrit \
par un élève francophone (niveau {niveau}). Il l'a tapé lui-même : l'orthographe, les \
accents écrits, les signes ¿ et ¡ comptent, comme la grammaire.

Relève uniquement les vraies fautes : grammaire (accords, conjugaison, prépositions, \
ser/estar…), vocabulaire, tournure qu'un Espagnol n'écrirait pas, orthographe (lettres, \
accents, ¿ ¡). Ne relève pas le style, ni une phrase correcte qu'on pourrait écrire \
autrement. Une phrase correcte n'a rien à faire dans la liste.

Pour chaque phrase fautive, donne :
- "said" : la phrase de l'élève, telle quelle ;
- "corrected" : la même phrase corrigée, en changeant le moins possible ;
- "explanation" : en français, une phrase courte qui dit la règle ;
- "category" : "grammaire", "vocabulaire", "tournure" ou "orthographe" ;
- "tag" : le point précis, en quelques mots, toujours nommé de la même façon \
(par exemple "ser/estar", "accord du verbe", "por/para", "accent écrit").

Donne aussi "corrected_text" : le texte entier, corrigé en changeant le moins possible \
(le texte tel quel s'il n'a pas de faute).

Si l'élève n'a fait aucune faute, renvoie une liste vide."""

CONSIGNE_OBJECTIF = """

L'objectif travaillé : « {titre} ». Règle : {regle} Critère de réussite : {validation}

Dans "objective_uses", mets chaque phrase de l'élève où il emploie, ou essaie d'employer, \
cet objectif :
- "said" : la phrase de l'élève, telle quelle ;
- "valide" : true si la phrase remplit le critère de réussite, sans faute sur ce point ; \
false sinon ;
- "analyse_courte" : en français, une phrase qui dit pourquoi.
Une phrase juste qui contourne l'objectif n'y entre pas. Si l'élève ne l'a jamais tenté, \
renvoie une liste vide. Les fautes de ces phrases vont aussi dans "corrections"."""


class Correction(BaseModel):
    said: str
    corrected: str
    explanation: str
    # Pour le profil d'apprenant : quel genre de faute, et sur quel point. Le
    # point est du texte libre tant qu'on n'a pas vu ce que l'IA en fait.
    category: Literal["grammaire", "vocabulaire", "tournure"]
    tag: str


class CorrectionEcrite(Correction):
    # À l'écrit, l'orthographe compte. Une catégorie à part : l'app d'aujourd'hui ne la
    # connaît pas, et la conversation ne la rend jamais.
    category: Literal["grammaire", "vocabulaire", "tournure", "orthographe"]


class UsageObjectif(BaseModel):
    """Une phrase où l'apprenant a tenté l'objectif, jugée (noms du doc du moteur)."""
    said: str
    valide: bool
    analyse_courte: str


class Corrections(BaseModel):
    corrections: list[Correction] = Field(default_factory=list)


class CorrectionsObjectif(Corrections):
    objective_uses: list[UsageObjectif] = Field(default_factory=list)


class CorrectionsEcrit(BaseModel):
    corrections: list[CorrectionEcrite] = Field(default_factory=list)
    corrected_text: str


class CorrectionsEcritObjectif(CorrectionsEcrit):
    objective_uses: list[UsageObjectif] = Field(default_factory=list)


def _consigne_objectif(objectif: Objectif | None) -> str:
    if objectif is None:
        return ""
    return CONSIGNE_OBJECTIF.format(titre=objectif.titre.strip(), regle=objectif.regle.strip(),
                                    validation=objectif.validation.strip() or "—")


def messages_correction(historique: list[Message], objectif: Objectif | None = None,
                        niveau: str | None = None) -> list[dict]:
    """La conversation en un seul texte : l'IA corrige un document, elle ne
    continue pas le dialogue."""
    lignes = [f"{'Élève' if m.role == 'user' else 'Partenaire'} : {m.content}" for m in historique]
    systeme = (CONSIGNE_CORRECTION_MODELE.format(niveau=niveau or NIVEAU_PAR_DEFAUT)
               + _consigne_objectif(objectif))
    return [{"role": "system", "content": systeme}, {"role": "user", "content": "\n".join(lignes)}]


def messages_ecrit(texte: str, objectif: Objectif | None = None,
                   niveau: str | None = None) -> list[dict]:
    systeme = CONSIGNE_ECRIT.format(niveau=niveau or NIVEAU_PAR_DEFAUT) + _consigne_objectif(objectif)
    return [{"role": "system", "content": systeme}, {"role": "user", "content": texte}]


def _a_l_oral(texte: str) -> str:
    """Ce qui s'entend d'une phrase : sans casse, ponctuation ni accents écrits, que
    Whisper met à sa façon."""
    sans_marques = "".join(c for c in unicodedata.normalize("NFD", texte.lower())
                           if not unicodedata.combining(c))
    return " ".join("".join(c if c.isalnum() else " " for c in sans_marques).split())


def vraies_corrections(corrections: list[Correction], ecrit: bool = False) -> list[Correction]:
    """Écarte une « correction » qui rend la phrase telle quelle : Qwen3 en renvoie
    (essai du 2026-11-18). À l'oral, la casse, la ponctuation et les accents ne
    comptent pas ; à l'écrit, si : seule la phrase identique est écartée."""
    meme = (lambda a, b: " ".join(a.split()) == " ".join(b.split())) if ecrit else (
        lambda a, b: _a_l_oral(a) == _a_l_oral(b))
    return [c for c in corrections if not meme(c.said, c.corrected)]
