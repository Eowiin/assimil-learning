"""Le texte du bloc 2 : un texte à lire et à écouter, écrit pour l'apprenant.

L'IA l'écrit phrase par phrase, avec la traduction (`Moteurs.rediger`). spaCy le mesure :
95 % de mots connus visés, nouvelle formulation sous 92 %, deux fois au plus (la
mécanique de la réplique, `conversation.ameliorer`). Les mots nouveaux du jour comptent
comme connus : ils sont là pour être appris. Les noms propres et les nombres ne comptent
pas (`Langue.mots`). Rien ici ne charge de modèle.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable

from pydantic import BaseModel, Field

from .conversation import STYLE, STYLES, Niveau, Objectif, ameliorer
from .langue import Couverture, Langue
from .llm import LLMIndisponible

SEUIL_TEXTE = 0.92
CIBLE_TEXTE = 0.95
# Les phrases qui doivent employer l'objectif.
PHRASES_OBJECTIF = 3
# Une version plus courte ou plus longue que ça, par rapport à `target_words`, est écartée.
LONGUEUR_MIN, LONGUEUR_MAX = 0.6, 1.5
INCONNUS_AU_PLUS = 15


class Phrase(BaseModel):
    es: str
    fr: str
    # L'IA marque les phrases qui emploient l'objectif. C'est elle qui le dit : rien ne
    # le juge.
    objective: bool


class Redaction(BaseModel):
    sentences: list[Phrase]


class InputRequest(BaseModel):
    level: Niveau
    theme: str = Field(min_length=1)
    objective: Objectif
    known_lemmas: list[str] = Field(default_factory=list)
    new_lemmas: list[str] = Field(min_length=6, max_length=8)
    target_words: int = Field(ge=30, le=400)


class SentencePair(BaseModel):
    es: str
    fr: str


class InputText(BaseModel):
    """`objective_hits` : les places (à partir de 0) des phrases qui emploient l'objectif,
    d'après l'IA. `unknown_lemmas` : les lemmes inconnus, mots nouveaux exclus.
    `new_used` : les mots nouveaux présents dans le texte."""
    text: str
    sentences: list[SentencePair]
    coverage: float
    unknown_lemmas: list[str]
    new_used: list[str]
    objective_hits: list[int]
    attempts: int


CONSIGNE_TEXTE = """Escribe un texto en español de España para un estudiante francés de \
nivel {niveau}: una pequeña historia o un diálogo sobre este tema: {theme}.

Reglas:
- Unas {mots} palabras en total. {style}
- Usa todas estas palabras nuevas, cada una al menos una vez, en un contexto que ayude a \
entenderlas: {nouveaux}.
- El texto trabaja este punto, descrito en francés solo para ti: «{point}». Úsalo de forma \
natural en al menos {n} frases.
- Fuera de las palabras nuevas, usa solo palabras muy corrientes.
- Nada de títulos, listas ni comentarios.

Da el texto frase por frase: "es", la frase en español; "fr", su traducción al francés, \
fiel y natural; "objective": true si la frase usa el punto trabajado, false si no."""

CONSIGNE_REECRIRE = """Reescribe este texto para un estudiante francés de español (nivel \
{niveau}), con palabras más corrientes.

Reglas:
- Estas palabras son demasiado difíciles para él: {inconnus}. Cámbialas por palabras más \
corrientes, o dilo de otra manera.
- Conserva estas palabras nuevas, que está aprendiendo: {nouveaux}.
- Conserva la historia y el punto trabajado («{point}») en las mismas frases.
- La misma longitud: unas {mots} palabras.

Da el texto frase por frase: "es", la frase en español; "fr", su traducción al francés; \
"objective": true si la frase usa el punto trabajado, false si no."""


def _point(objectif: Objectif) -> str:
    return f"{objectif.titre.strip()} : {objectif.regle.strip()}"


def _nouveaux(demande: InputRequest) -> list[str]:
    return [m.strip() for m in demande.new_lemmas if m.strip()]


def messages_texte(demande: InputRequest) -> list[dict]:
    consigne = CONSIGNE_TEXTE.format(
        niveau=demande.level, theme=demande.theme.strip(),
        mots=demande.target_words, style=STYLES.get(demande.level, STYLE),
        nouveaux=", ".join(_nouveaux(demande)), point=_point(demande.objective),
        n=PHRASES_OBJECTIF)
    return [{"role": "system", "content": consigne},
            {"role": "user", "content": "(Escribe el texto.)"}]


def messages_reecrire(demande: InputRequest, avant: Redaction, inconnus: list[str]) -> list[dict]:
    consigne = CONSIGNE_REECRIRE.format(
        niveau=demande.level, inconnus=", ".join(inconnus[:INCONNUS_AU_PLUS]),
        nouveaux=", ".join(_nouveaux(demande)), point=_point(demande.objective),
        mots=demande.target_words)
    return [{"role": "system", "content": consigne},
            {"role": "user", "content": "\n".join(p.es for p in avant.sentences)}]


def _propre(redaction: Redaction) -> Redaction:
    """Sans phrase vide."""
    return Redaction(sentences=[Phrase(es=p.es.strip(), fr=p.fr.strip(), objective=p.objective)
                                for p in redaction.sentences if p.es.strip()])


def texte_de(redaction: Redaction) -> str:
    return " ".join(p.es for p in redaction.sentences)


def _bonne_longueur(redaction: Redaction, cible: int) -> bool:
    mots = len(texte_de(redaction).split())
    return LONGUEUR_MIN * cible <= mots <= LONGUEUR_MAX * cible


Rediger = Callable[[list[dict], type[Redaction]], Redaction]


def generer(demande: InputRequest, rediger: Rediger, langue: Langue) -> InputText:
    """Le texte, mesuré et réécrit s'il le faut. Si l'IA tombe à la première version,
    `LLMIndisponible` remonte ; pendant une réécriture, la meilleure version sert."""
    nouveaux = _nouveaux(demande)
    connus = {l.strip().lower() for l in [*demande.known_lemmas, *nouveaux] if l.strip()}

    def mesure(r: Redaction) -> Couverture:
        return langue.couverture(texte_de(r), connus)

    def reecrire(avant: Redaction, couverture: Couverture) -> Redaction | None:
        version = _propre(rediger(messages_reecrire(demande, avant, couverture.inconnus), Redaction))
        return version if version.sentences and _bonne_longueur(version, demande.target_words) else None

    premiere = _propre(rediger(messages_texte(demande), Redaction))
    if not premiere.sentences:
        raise LLMIndisponible("l'IA a rendu un texte vide.")
    redaction, couverture, essais = ameliorer(premiere, mesure, reecrire, SEUIL_TEXTE, CIBLE_TEXTE)
    texte = texte_de(redaction)
    return InputText(
        text=texte,
        sentences=[SentencePair(es=p.es, fr=p.fr) for p in redaction.sentences],
        coverage=round(couverture.taux, 3),
        unknown_lemmas=couverture.inconnus,
        new_used=presents(nouveaux, langue, texte),
        objective_hits=[i for i, p in enumerate(redaction.sentences) if p.objective],
        attempts=essais)


def presents(lemmes: Iterable[str], langue: Langue, texte: str) -> list[str]:
    """Les lemmes de la liste qui apparaissent dans le texte (par lemme ou par forme),
    dans l'ordre de la liste."""
    vus = set()
    for mot in langue.mots(texte):
        vus.update((mot.lemme, mot.forme))
    return [l for l in lemmes if l.lower() in vus]
