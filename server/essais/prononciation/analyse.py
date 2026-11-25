"""L'analyse de prononciation, telle que le serveur la fait (`app/prononciation/`),
lancée sur un enregistrement.

Usage : analyse.py AUDIO "phrase attendue"
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from app.prononciation.analyse import (MODELE, SEUILS_ZIPA, ZIPA, Analyseur,  # noqa: E402,F401
                                       parts_zipa)
from app.prononciation.coach.acoustic import load_audio as charger_audio  # noqa: E402


def afficher(resultat):
    print("entendu :", " ".join(resultat["entendu"]))
    for indice, mot in enumerate(resultat["mots"]):
        sons = [p for p in resultat["phonemes"] if p["mot"] == indice]
        rendu = " ".join(
            f"[{p['attendu']}→{p['variante']} {p['raison']}]" if p["faute"] else p["attendu"]
            for p in sons)
        print(f"  {mot:15} {rendu}")


if __name__ == "__main__":
    afficher(Analyseur().analyser(charger_audio(sys.argv[1]), sys.argv[2]))
