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

Relève uniquement les vraies fautes de l'élève : grammaire (accords, conjugaison, \
prépositions, ser/estar…), vocabulaire, ou tournure qu'un Espagnol ne dirait pas. \
Ne relève pas le style, ni une phrase correcte qu'on pourrait dire autrement.

Pour chaque phrase fautive, donne :
- "said" : la phrase de l'élève, telle quelle ;
- "corrected" : la même phrase corrigée, en changeant le moins possible ;
- "explanation" : en français, une phrase courte qui dit la règle.

Si l'élève n'a fait aucune faute, renvoie une liste vide."""


class Message(BaseModel):
    """Une réplique de la conversation, telle que l'app la garde."""
    role: Literal["user", "assistant"]
    content: str


class Correction(BaseModel):
    said: str
    corrected: str
    explanation: str


class Corrections(BaseModel):
    corrections: list[Correction] = Field(default_factory=list)


class Moteurs(Protocol):
    """Ce que le serveur attend des modèles. `moteurs.Reels` les charge vraiment ;
    les tests en passent un faux."""

    def ecouter(self, audio: bytes) -> str:
        """La transcription d'un enregistrement (n'importe quel format lu par ffmpeg)."""
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


def messages_ouverture(sujet: str | None) -> list[dict]:
    consigne = OUVERTURE_SUJET.format(sujet=sujet.strip()) if sujet and sujet.strip() else OUVERTURE
    return [{"role": "system", "content": CONSIGNE}, {"role": "user", "content": consigne}]


def messages_tour(historique: list[Message], phrase: str) -> list[dict]:
    return ([{"role": "system", "content": CONSIGNE}]
            + [m.model_dump() for m in historique]
            + [{"role": "user", "content": phrase}])


def messages_correction(historique: list[Message]) -> list[dict]:
    """La conversation en un seul texte : l'IA corrige un document, elle ne
    continue pas le dialogue."""
    lignes = [f"{'Élève' if m.role == 'user' else 'Partenaire'} : {m.content}" for m in historique]
    return [{"role": "system", "content": CONSIGNE_CORRECTION},
            {"role": "user", "content": "\n".join(lignes)}]
