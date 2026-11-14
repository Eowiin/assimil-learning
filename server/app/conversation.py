"""La conversation : les consignes données à l'IA, et la forme des échanges.

Rien ici ne charge de modèle : les modèles sont dans `moteurs.py`, derrière
l'interface `Moteurs`, que les tests remplacent par un faux.
"""

from __future__ import annotations

from typing import Literal, Protocol

from pydantic import BaseModel, Field

CONSIGNE = """Eres un compañero de conversación para un estudiante francés de español \
(nivel A2-B1, español de España). Habláis de forma natural, como dos amigos.

Reglas:
- Responde siempre en español de España, en 1 a 3 frases cortas.
- Reacciona primero a lo que acaba de decir el estudiante, como haría un amigo que escucha.
- Si dice que no conoce o no entiende una palabra, explícasela con palabras sencillas antes de seguir.
- Usa un vocabulario sencillo y frases claras.
- Termina siempre con una pregunta para que la conversación siga.
- No corrijas los errores del estudiante durante la conversación: responde a lo que quiso decir.
- Nada de listas, emojis, asteriscos ni formato: tu respuesta se leerá en voz alta."""

# Une consigne de tour, pas un message de l'apprenant : elle n'entre pas dans
# l'historique que l'app garde.
OUVERTURE = ("(Empieza tú la conversación: saluda al estudiante y propón un tema de la vida "
             "cotidiana con una pregunta sencilla.)")
OUVERTURE_SUJET = ("(Empieza tú la conversación: saluda al estudiante y propón hablar de este "
                   "tema, con una pregunta sencilla: {sujet})")

CONSIGNE_CORRECTION = """Tu es professeur d'espagnol (espagnol d'Espagne). Voici une \
conversation entre un élève francophone (niveau A2-B1) et son partenaire. Les phrases de \
l'élève ont été transcrites depuis sa voix : ignore la ponctuation, les majuscules et les \
accents écrits, qui viennent de la transcription.

La transcription (Whisper) se trompe parfois : un mot qui n'a pas de sens dans la phrase, \
ou qui ne ressemble à rien, vient sans doute d'elle et non de l'élève. Ne le corrige pas, \
et ne relève pas une phrase pour ça.

Relève uniquement les vraies fautes de l'élève : grammaire (accords, conjugaison, \
prépositions, ser/estar…), vocabulaire, ou tournure qu'un Espagnol ne dirait pas. \
Ne relève pas le style, ni une phrase correcte qu'on pourrait dire autrement.

Pour chaque phrase fautive, donne :
- "said" : la phrase de l'élève, telle quelle ;
- "corrected" : la même phrase corrigée, en changeant le moins possible ;
- "explanation" : en français, une phrase courte qui dit la règle ;
- "category" : "grammaire", "vocabulaire" ou "tournure" (une tournure qu'un Espagnol \
ne dirait pas) ;
- "tag" : le point précis, en quelques mots, toujours nommé de la même façon \
(par exemple "ser/estar", "accord du verbe", "por/para", "gustar").

Si l'élève n'a fait aucune faute, renvoie une liste vide."""


class Profil(BaseModel):
    """Ce que l'iPhone sait de l'apprenant, joint à la conversation
    (`docs/module-profil.md`, étape 3). Le serveur ne le garde pas."""
    # La faute qui revient le plus, telle que l'IA l'a nommée au récapitulatif.
    watch: str | None = None
    # Des mots compris en révision, pas encore sus dans l'autre sens.
    words: list[str] = Field(default_factory=list)


# Une consigne courte garde Qwen3 8B rapide et concentré.
MOTS_AU_PLUS = 5
# Le point qui revient : à l'ouverture, puis une réplique sur trois. À chaque tour,
# la conversation ne parle plus que de lui.
POINT_TOUS_LES = 3


def consigne(profil: Profil | None = None) -> str:
    """La consigne de conversation, avec le profil quand l'app en envoie un."""
    if profil is None:
        return CONSIGNE
    lignes = []
    if mots := _mots(profil):
        lignes.append("- El estudiante está aprendiendo estas palabras: " + ", ".join(mots)
                      + ". Úsalas en tus respuestas, una por respuesta, para que las oiga y se "
                      "anime a usarlas.")
    if surveiller := _surveiller(profil):
        lignes.append("- El estudiante suele equivocarse en este punto: «" + surveiller
                      + "». De vez en cuando, haz preguntas normales cuya respuesta lo necesite. "
                      "Nunca nombres el punto, nunca ofrezcas opciones como «eres o estás», y no "
                      "le corrijas.")
    return CONSIGNE + ("\n" + "\n".join(lignes) if lignes else "")


def _mots(profil: Profil | None) -> list[str]:
    return [m.strip() for m in profil.words if m.strip()][:MOTS_AU_PLUS] if profil else []


def _surveiller(profil: Profil | None) -> str | None:
    return profil.watch.strip() if profil and profil.watch and profil.watch.strip() else None


def note_du_tour(profil: Profil | None, rang: int, ouverture: bool = False) -> str | None:
    """La consigne précise d'une réplique, collée au message auquel l'IA répond. Un
    modèle de 8B suit mal une règle donnée en tête de conversation ; il suit bien
    une demande récente et précise : un seul mot, et une question qui oblige à
    employer le point. `rang` : le nombre de répliques déjà faites par l'IA, qui
    fait tourner les mots. La note n'entre pas dans l'historique que l'app garde."""
    demandes = []
    if mots := _mots(profil):
        demandes.append(f"usa la palabra «{mots[rang % len(mots)]}» si encaja sin forzar")
    if (surveiller := _surveiller(profil)) and rang % POINT_TOUS_LES == 0:
        demandes.append(f"termina con una pregunta normal y natural, sin ofrecer opciones ni "
                        f"nombrar el punto, cuya respuesta lleve al estudiante a usar «{surveiller}»")
    if not demandes:
        return None
    # D'abord répondre à ce qu'il vient de dire : sans ça, le modèle ne fait plus
    # que ce que la note demande.
    if ouverture:
        return "(En esta primera réplica, " + ", y ".join(demandes) + ".)"
    return ("(Nota para ti, no la menciones: primero responde de verdad a lo que acaba de decir. "
            "Después, en la misma respuesta, " + ", y ".join(demandes) + ".)")


class Message(BaseModel):
    """Une réplique de la conversation, telle que l'app la garde."""
    role: Literal["user", "assistant"]
    content: str


class Correction(BaseModel):
    said: str
    corrected: str
    explanation: str
    # Pour le profil d'apprenant : quel genre de faute, et sur quel point. Le
    # point est du texte libre tant qu'on n'a pas vu ce que l'IA en fait.
    category: Literal["grammaire", "vocabulaire", "tournure"]
    tag: str


class Corrections(BaseModel):
    corrections: list[Correction] = Field(default_factory=list)


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

    def corriger(self, messages: list[dict]) -> Corrections:
        """Les corrections, demandées dans un format imposé."""
        ...

    def dire(self, texte: str) -> bytes:
        """La réplique à voix haute, en AAC (.m4a)."""
        ...


def messages_ouverture(sujet: str | None, profil: Profil | None = None) -> list[dict]:
    ouverture = OUVERTURE_SUJET.format(sujet=sujet.strip()) if sujet and sujet.strip() else OUVERTURE
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


def messages_correction(historique: list[Message]) -> list[dict]:
    """La conversation en un seul texte : l'IA corrige un document, elle ne
    continue pas le dialogue."""
    lignes = [f"{'Élève' if m.role == 'user' else 'Partenaire'} : {m.content}" for m in historique]
    return [{"role": "system", "content": CONSIGNE_CORRECTION},
            {"role": "user", "content": "\n".join(lignes)}]
