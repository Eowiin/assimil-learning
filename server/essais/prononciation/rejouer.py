"""Rejoue l'analyse de prononciation sur des prises déjà enregistrées, puis en fait
le bilan : les fautes faites exprès sont-elles repérées, et les sons justes
laissés tranquilles ?

Les prises sont celles du test du 10 novembre 2026 : 8 phrases, chacune dite une
fois soignée et une fois avec les fautes d'un francophone. Elles viennent du Mac
(`empaqueter.py`), un .wav et un .json par prise, hors dépôt.

    uv run python essais/prononciation/rejouer.py ~/prises-10-novembre
    ASSIMIL_PRONONCIATION_MODELE=lv60 uv run python essais/prononciation/rejouer.py ~/prises-10-novembre

Le prototype du 10 novembre repérait 8 fautes sur 34, et signalait 24 phonèmes sur 218
dans la prise soignée. La méthode de spanish-pronunciation-coach (analyse.py), le
13 novembre : 29 sur 34, et 13 sur 218.
"""
import argparse
import glob
import json
import os
import sys
import time

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)

from analyse import Analyseur  # noqa: E402
from entendre import MODELE, charger_audio  # noqa: E402
import bilan  # noqa: E402


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("prises", help="le dossier des prises (.wav et .json)")
    p.add_argument("--sortie", default=os.path.join(ICI, "..", "sortie", "prononciation"))
    args = p.parse_args()

    fichiers = sorted(glob.glob(os.path.join(args.prises, "*.json")))
    if not fichiers:
        return print(f"Aucune prise dans {args.prises}")
    os.makedirs(args.sortie, exist_ok=True)
    for ancien in glob.glob(os.path.join(args.sortie, "*.json")):
        os.remove(ancien)

    print(f"Modèle : {MODELE}")
    debut = time.perf_counter()
    analyseur = Analyseur()
    print(f"Chargé en {time.perf_counter() - debut:.1f} s, sur {analyseur.modele.device} (ZIPA sur cpu)")

    durees = []
    for chemin in fichiers:
        prise = json.load(open(chemin))
        audio = os.path.join(args.prises, os.path.basename(prise["audio"]))
        texte = prise.get("texte") or " ".join(prise["mots"])
        debut = time.perf_counter()
        resultat = analyseur.analyser(charger_audio(audio), texte)
        durees.append(time.perf_counter() - debut)
        sortie = {**prise, **resultat, "audio": audio}
        with open(os.path.join(args.sortie, os.path.basename(chemin)), "w") as f:
            json.dump(sortie, f, ensure_ascii=False)
        fautes = sum(ph["faute"] for ph in resultat["phonemes"])
        print(f"  {prise['phrase']}. {prise['essai']:7} {fautes:2} signalé(s)  ({durees[-1]:.2f} s)")

    print(f"\nAnalyse : {sum(durees) / len(durees):.2f} s par phrase en moyenne")
    sys.argv = ["bilan.py", args.sortie]
    bilan.main()


if __name__ == "__main__":
    main()
