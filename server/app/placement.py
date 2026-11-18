"""Le placement : des défis jugés en trois verdicts (décision 7 du moteur adaptatif).

Un défi vise un micro-objectif. La réponse de l'apprenant est :
- `shown` : juste, et elle montre l'objectif ;
- `correct_not_shown` : juste, mais elle le contourne (« debe de estar » au lieu du futur
  de probabilité) ; l'app repose un défi, sans compter de lacune ;
- `wrong` : fausse.
Le type du défi (`complete`, `translate`, `rewrite`) ne change rien au correcteur.

Une réponse vide, ou identique à une réponse du paquet, est triée sans l'IA. Les autres
vont au juge (`Moteurs.structurer`), par paquets numérotés : le juge rend un numéro, pas
un identifiant qu'il pourrait mal recopier. Rien ici ne charge de modèle.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Literal

from pydantic import BaseModel, Field

from .conversation import NIVEAU_PAR_DEFAUT, Niveau
from .llm import LLMIndisponible

Verdict = Literal["shown", "correct_not_shown", "wrong"]

# Les défis envoyés au juge en une fois : assez pour aller vite, assez peu pour qu'il
# n'en oublie pas.
PAR_PAQUET = 10
# Un passage du placement entier : un défi par objectif.
DEFIS_AU_PLUS = 125


class Defi(BaseModel):
    """Un défi de `placement_challenges.json`, avec la réponse de l'apprenant.
    `instruction` : la mise en situation (« Il est 16 h… »), qui peut décider de la
    bonne réponse."""
    objective_id: str
    instruction: str = ""
    prompt: str
    expected: list[str] = Field(min_length=1)
    also_correct: list[str] = Field(default_factory=list)
    check: str
    answer: str


class JugementDefi(BaseModel):
    """Ce que la route rend, pour un défi."""
    objective_id: str
    verdict: Verdict
    analyse_courte: str


class JugementNumerote(BaseModel):
    numero: int
    verdict: Verdict
    analyse_courte: str


class Jugements(BaseModel):
    jugements: list[JugementNumerote]


DEJA_ATTENDUE = "Réponse attendue."
DEJA_CONTOURNEE = "Réponse juste, qui n'emploie pas l'objectif."
VIDE = "Pas de réponse."


def _comparable(texte: str) -> str:
    """Sans casse, ponctuation ni espaces en trop. Les accents restent : certains
    critères les exigent."""
    return " ".join("".join(c if c.isalnum() else " " for c in texte.lower()).split())


def trier(defi: Defi) -> JugementDefi | None:
    """Le verdict d'une réponse qui n'a pas besoin du juge, ou None."""
    reponse = _comparable(defi.answer)
    if not reponse:
        return JugementDefi(objective_id=defi.objective_id, verdict="wrong", analyse_courte=VIDE)
    if any(reponse == _comparable(e) for e in defi.expected):
        return JugementDefi(objective_id=defi.objective_id, verdict="shown", analyse_courte=DEJA_ATTENDUE)
    if any(reponse == _comparable(e) for e in defi.also_correct):
        return JugementDefi(objective_id=defi.objective_id, verdict="correct_not_shown",
                        analyse_courte=DEJA_CONTOURNEE)
    return None


CONSIGNE_PLACEMENT = """Tu es examinateur d'espagnol (espagnol d'Espagne). Un élève \
francophone (niveau estimé {niveau}) passe un test de placement. Chaque défi vise un \
objectif de grammaire ou de vocabulaire. Pour chacun, tu as : la consigne, l'énoncé, des \
réponses qui montrent l'objectif, des réponses justes qui le contournent, le critère de \
réussite, et la réponse de l'élève.

Donne pour chaque défi un verdict :
- "shown" : la réponse est juste et montre l'objectif selon le critère. Une autre \
formulation que les réponses données compte, si elle est juste et remplit le critère.
- "correct_not_shown" : la réponse est de l'espagnol correct et répond au défi, mais elle \
contourne l'objectif (une autre tournure juste, comme « debe de estar » au lieu du futur \
de probabilité).
- "wrong" : une faute sur l'objectif, une faute qui rend la réponse fausse, ou une réponse \
qui ne répond pas au défi.

Le type d'exercice (compléter, traduire, réécrire) ne change rien : seuls comptent la \
réponse et le critère. La ponctuation, les majuscules et les signes ¿ ¡ ne comptent pas ; \
pour les accents écrits, suis le critère. Une petite faute qui ne touche pas l'objectif \
ne change pas le verdict si le critère est rempli : dis-la dans l'analyse.

Pour chaque défi, rends "numero" (celui du défi), "verdict", et "analyse_courte" : en \
français, une phrase qui dit pourquoi. Un jugement par défi, sans en oublier."""


def _liste(reponses: list[str]) -> str:
    return " ; ".join(f"« {r.strip()} »" for r in reponses) if reponses else "aucune"


def _decrire(numero: int, defi: Defi) -> str:
    lignes = [f"Défi {numero}"]
    if defi.instruction.strip():
        lignes.append(f"Consigne : {defi.instruction.strip()}")
    lignes += [f"Énoncé : {defi.prompt.strip()}",
               f"Réponses qui montrent l'objectif : {_liste(defi.expected)}",
               f"Réponses justes qui le contournent : {_liste(defi.also_correct)}",
               f"Critère : {defi.check.strip()}",
               f"Réponse de l'élève : « {defi.answer.strip()} »"]
    return "\n".join(lignes)


def messages_placement(defis: list[Defi], niveau: str | None = None) -> list[dict]:
    """Les défis numérotés à partir de 1, dans l'ordre."""
    return [{"role": "system", "content": CONSIGNE_PLACEMENT.format(niveau=niveau or NIVEAU_PAR_DEFAUT)},
            {"role": "user", "content": "\n\n".join(_decrire(i, d) for i, d in enumerate(defis, 1))}]


Juger = Callable[[list[dict], type[Jugements]], Jugements]


def _juger_paquet(defis: list[Defi], juger: Juger, niveau: str | None) -> dict[int, JugementNumerote]:
    """Les jugements rendus pour ce paquet, par place dans le paquet (à partir de 0).
    Un numéro hors du paquet est écarté ; en double, le premier compte."""
    rendus: dict[int, JugementNumerote] = {}
    for j in juger(messages_placement(defis, niveau), Jugements).jugements:
        if 1 <= j.numero <= len(defis):
            rendus.setdefault(j.numero - 1, j)
    return rendus


def evaluer(defis: list[Defi], juger: Juger, niveau: str | None = None) -> list[JugementDefi]:
    """Un verdict par défi, dans l'ordre. Un défi que le juge oublie est rejugé seul,
    une fois ; s'il manque encore, `LLMIndisponible` : mieux vaut une erreur qu'un
    verdict inventé."""
    verdicts: list[JugementDefi | None] = [trier(d) for d in defis]
    restants = [i for i, v in enumerate(verdicts) if v is None]
    for debut in range(0, len(restants), PAR_PAQUET):
        places = restants[debut:debut + PAR_PAQUET]
        rendus = _juger_paquet([defis[i] for i in places], juger, niveau)
        for k, i in enumerate(places):
            if k not in rendus and 0 in (seul := _juger_paquet([defis[i]], juger, niveau)):
                rendus[k] = seul[0]
            if k not in rendus:
                raise LLMIndisponible(f"le juge n'a pas rendu de verdict pour {defis[i].objective_id}.")
            verdicts[i] = JugementDefi(objective_id=defis[i].objective_id, verdict=rendus[k].verdict,
                                   analyse_courte=rendus[k].analyse_courte)
    return verdicts  # type: ignore[return-value]


class PlacementRequest(BaseModel):
    level: Niveau | None = None
    items: list[Defi] = Field(min_length=1, max_length=DEFIS_AU_PLUS)
