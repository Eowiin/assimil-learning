"""Les amorces et la fin de scène (étape 5b), avec Mistral.

Ni Whisper ni XTTS ne sont chargés : seulement l'IA (`app.llm.choisir_llm`, comme le
serveur). Pour le premier objectif A0 et le premier A1 du paquet de l'app, en jeu de
rôle :

1. **L'ouverture**, puis ses amorces : trois débuts de réponse, chacun avec sa
   traduction. À regarder : répondent-ils à la question ? sont-ils assez simples ?
2. **Un tour**, la réponse d'un débutant, puis ses amorces.
3. **La dernière réponse** (`closing`) : l'IA doit conclure la scène, sans question.

    uv run python essais/amorces.py
    uv run python essais/amorces.py --niveaux A1 A2   # d'autres niveaux
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.conversation import (Amorces, Message, Objectif, Profil, amorces_propres,  # noqa: E402
                              messages_amorces, messages_ouverture, messages_tour)
from app.llm import LLMIndisponible, choisir_llm  # noqa: E402

PAQUET = Path(__file__).resolve().parents[2] / "Resources/curriculum/es"
# Ce que dit un débutant, en réponse à n'importe quelle ouverture.
REPONSE = "Bien, gracias. Quiero un café."
ADIEU = "Gracias, adiós."


def premier_objectif(niveau: str) -> Objectif:
    tous = json.loads((PAQUET / "objectives.json").read_text(encoding="utf-8"))["objectives"]
    o = next(o for o in tous if o["niveau"] == niveau and o.get("prompt_ia"))
    return Objectif(id=o["id"], titre=o["titre"], regle=o["regle"], prompt_ia=o["prompt_ia"],
                    validation=o.get("validation", ""))


def chrono(fonction, *args, **kwargs):
    debut = time.perf_counter()
    resultat = fonction(*args, **kwargs)
    return resultat, time.perf_counter() - debut


def montrer_amorces(llm, historique: list[Message], replique: str, profil: Profil) -> None:
    brutes, duree = chrono(llm.structured, messages_amorces(historique, replique, profil), Amorces)
    print(f"   amorces ({duree:.1f} s) :")
    for amorce in amorces_propres(brutes):
        print(f"     · {amorce.es:<28} {amorce.fr}")


def essayer(llm, niveau: str) -> None:
    obj = premier_objectif(niveau)
    profil = Profil(level=niveau, objective=obj, mode="roleplay", hints=True)
    print(f"\n== {niveau} · {obj.id} · {obj.titre}")

    ouverture, duree = chrono(llm.chat, messages_ouverture(None, profil), temperature=0.7)
    print(f"\n1. IA ({duree:.1f} s) : {ouverture}")
    historique = [Message(role="assistant", content=ouverture)]
    montrer_amorces(llm, [], ouverture, profil)

    replique, duree = chrono(llm.chat, messages_tour(historique, REPONSE, profil), temperature=0.7)
    print(f"\n2. Moi : {REPONSE}\n   IA ({duree:.1f} s) : {replique}")
    historique += [Message(role="user", content=REPONSE), Message(role="assistant", content=replique)]
    montrer_amorces(llm, historique[-2:-1], replique, profil)

    fin, duree = chrono(llm.chat, messages_tour(historique, ADIEU, profil, fin=True), temperature=0.7)
    print(f"\n3. Moi : {ADIEU}\n   IA, dernière réplique ({duree:.1f} s) : {fin}")
    print("   (à vérifier : elle conclut, sans question)" if "?" not in fin
          else "   ⚠ elle pose encore une question")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--niveaux", nargs="+", default=["A0", "A1"])
    args = parser.parse_args()
    llm = choisir_llm()
    try:
        for niveau in args.niveaux:
            essayer(llm, niveau)
    except LLMIndisponible as erreur:
        sys.exit(f"L'IA ne répond pas : {erreur}")


if __name__ == "__main__":
    main()
