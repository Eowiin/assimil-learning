"""La langue : les lemmes d'un texte espagnol, et la part qu'en connaît l'apprenant.

Sert à mesurer ce que l'IA écrit : la réplique d'une conversation (sous 85 % de
mots connus, elle est réécrite plus simple), et le texte du bloc 2 (95 % visés,
reformulé sous 92 %). Le vrai analyseur est spaCy (`analyse.Spacy`), chargé au
démarrage ; les tests des routes passent un faux, qui n'a qu'à découper les mots.

Le serveur ne garde pas de lexique : l'app envoie les lemmes connus à chaque
demande (décision 2 du moteur adaptatif).
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Iterable
from dataclasses import dataclass


@dataclass(frozen=True)
class Mot:
    """Un mot qui compte : ni nom propre, ni nombre, ni ponctuation, ni symbole.
    `forme` : tel qu'écrit, en minuscules. `lemme` : sa forme de dictionnaire."""
    forme: str
    lemme: str


@dataclass(frozen=True)
class Couverture:
    """`taux` : la part des mots du texte qui sont connus, chaque occurrence comptée
    (un mot répété compte autant de fois qu'il apparaît). `inconnus` : les lemmes
    inconnus, une fois chacun, dans l'ordre où ils apparaissent. `mots` : combien de
    mots ont compté."""
    taux: float
    inconnus: list[str]
    mots: int


def couvrir(mots: Iterable[Mot], connus: Iterable[str]) -> Couverture:
    """Un mot est connu si son lemme ou sa forme est dans `connus`. La forme sert de
    filet : le lexique de l'app a été nettoyé (Hunspell, pluriels réparés), spaCy en
    direct peut se tromper de lemme sur un mot que l'apprenant connaît bien.
    Un texte sans aucun mot qui compte est couvert en entier."""
    connus = {c.lower() for c in connus}
    total = 0
    sus = 0
    inconnus: dict[str, None] = {}
    for mot in mots:
        total += 1
        if mot.lemme in connus or mot.forme in connus:
            sus += 1
        else:
            inconnus.setdefault(mot.lemme)
    return Couverture(taux=sus / total if total else 1.0, inconnus=list(inconnus), mots=total)


class Langue(ABC):
    """Ce que les routes attendent. Une implémentation n'a qu'à découper un texte en
    `Mot` ; lemmatiser et mesurer s'en déduisent."""

    nom: str

    @abstractmethod
    def mots(self, texte: str) -> list[Mot]:
        """Les mots qui comptent, dans l'ordre du texte. Le texte est toujours analysé
        en entier : un mot seul ne dit pas son lemme (« vino » : le vin, ou venir ?)."""

    def lemmatiser(self, texte: str) -> list[str]:
        return [m.lemme for m in self.mots(texte)]

    def couverture(self, texte: str, connus: Iterable[str]) -> Couverture:
        return couvrir(self.mots(texte), connus)
