"""Résume les analyses de rejouer.py : les seuils laissent-ils passer les vraies fautes ?

Pour chaque phrase et chaque essai, seule la dernière prise compte (une prise
refaite remplace la précédente).

- soigne : tout phonème signalé est une fausse alerte.
- fautes : chaque son visé (θ, jota, r, v) devait être signalé. Le bilan donne le
  taux de détection par faute, et l'écart des scores au seuil : une faute manquée de
  peu se rattrape en ajustant un seuil, une faute notée comme juste non.

Usage : bilan.py DOSSIER  (les analyses écrites par rejouer.py)
"""
import collections
import glob
import json
import os
import statistics
import sys

from analyse import SEUILS
from fautes import FAUTES, cibles

SEUILS_PAR_SON = json.load(open(SEUILS))


def dernieres_prises(dossier):
    prises = {}
    for chemin in glob.glob(os.path.join(dossier, "*.json")):
        prise = json.load(open(chemin))
        cle = (prise["phrase"], prise["essai"])
        if cle not in prises or prise.get("horodatage", 0) >= prises[cle].get("horodatage", 0):
            prises[cle] = prise
    return prises


def mediane(valeurs):
    return f"{statistics.median(valeurs):+5.1f}" if valeurs else "    –"


def main():
    dossier = sys.argv[1]
    prises = dernieres_prises(dossier)
    if not prises:
        return print(f"Aucune prise dans {dossier}")

    # (essai, faute) → [(score, seuil, signalé, entendu)]
    vises = collections.defaultdict(list)
    alertes = collections.defaultdict(list)  # essai → [(phrase, mot, attendu, entendu, score)]
    totaux = collections.Counter()
    for (n, essai), prise in sorted(prises.items()):
        visees = cibles(prise["mots"], prise["phonemes"])
        for p, faute in zip(prise["phonemes"], visees):
            totaux[essai] += 1
            if faute:
                vises[essai, faute].append((p["score"], SEUILS_PAR_SON.get(p["attendu"], 0.0),
                                            p["faute"], p["variante"]))
            elif p["faute"]:
                alertes[essai].append((n, prise["mots"][p["mot"]], p["attendu"], p["variante"], p["score"]))

    for essai in sorted({e for _, e in prises}):
        phrases = sorted(n for n, e in prises if e == essai)
        print(f"\n== {essai} : {len(phrases)} phrase(s), {totaux[essai]} phonèmes")
        print(f"   {'faute':6} {'signalés':>9}   {'score médian':>12}  {'seuil':>5}   son le plus proche quand non signalé")
        for faute in FAUTES:
            notes = vises[essai, faute]
            if not notes:
                continue
            signales = sum(s for _, _, s, _ in notes)
            manques = collections.Counter(v for _, _, s, v in notes if not s)
            seuils = sorted({seuil for _, seuil, _, _ in notes})
            print(f"   {faute:6} {signales:3}/{len(notes):<3}"
                  f"   {mediane([sc for sc, _, _, _ in notes]):>12}  {'/'.join(f'{x:.1f}' for x in seuils):>5}"
                  f"   {', '.join(f'{v} {c}' for v, c in manques.most_common(3))}")
        hors = alertes[essai]
        print(f"   autres phonèmes signalés : {len(hors)}")
        for n, mot, attendu, variante, score in hors:
            print(f"     {n}. {mot:12} {attendu}→{variante} {score:+.1f}")

    # Le cœur de la question : un son visé fait juste et fait faux, se séparent-ils ?
    print("\n== Écart soigné / fautes, par son visé (scores médians)")
    for faute in FAUTES:
        soigne = [sc for sc, *_ in vises["soigne", faute]]
        fautif = [sc for sc, *_ in vises["fautes", faute]]
        if soigne or fautif:
            print(f"   {faute:6} soigné {mediane(soigne)}   fautes {mediane(fautif)}")


if __name__ == "__main__":
    main()
