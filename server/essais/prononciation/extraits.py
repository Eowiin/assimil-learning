"""Découpe, pour chaque son signalé, un court extrait à écouter : le mot entier, avec
un peu de marge, pour juger à l'oreille si la faute est réelle.

Lit les analyses écrites par rejouer.py (un .json par prise, avec le chemin de l'audio).
Les positions viennent de l'alignement : les pics CTC arrivent tôt, d'où la marge.

    uv run python essais/prononciation/extraits.py essais/sortie/prononciation
"""
import argparse
import glob
import json
import os
import sys

import soundfile as sf

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)

from entendre import charger_audio  # noqa: E402

MARGE = 0.25  # secondes, de part et d'autre du mot
TAUX = 16000


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("analyses", help="le dossier des analyses (.json de rejouer.py)")
    p.add_argument("--sortie", help="où écrire les extraits (défaut : ANALYSES/extraits)")
    args = p.parse_args()
    sortie = args.sortie or os.path.join(args.analyses, "extraits")
    os.makedirs(sortie, exist_ok=True)

    n = 0
    for chemin in sorted(glob.glob(os.path.join(args.analyses, "*.json"))):
        prise = json.load(open(chemin))
        signales = [ph for ph in prise["phonemes"] if ph["faute"] and "debut" in ph]
        if not signales:
            continue
        audio = charger_audio(prise["audio"])
        nom = os.path.splitext(os.path.basename(chemin))[0]
        for ph in signales:
            sons = [x for x in prise["phonemes"] if x["mot"] == ph["mot"] and "debut" in x]
            debut = max(0, int((min(x["debut"] for x in sons) - MARGE) * TAUX))
            fin = min(len(audio), int((max(x["fin"] for x in sons) + MARGE) * TAUX))
            mot = prise["mots"][ph["mot"]]
            fichier = f"{nom}-{mot}-{ph['attendu']}-{ph['variante']}.wav"
            sf.write(os.path.join(sortie, fichier), audio[debut:fin], TAUX)
            print(f"  {fichier:50} {ph['raison']}")
            n += 1
    print(f"{n} extrait(s) dans {sortie}")


if __name__ == "__main__":
    main()
