"""Mesure l'analyse sur des voix inconnues : un manifeste TSV (fichier, texte, et
optionnellement groupe, locuteur), comme celui de common_voice.py.

- groupe « natif » : tout son signalé est une fausse alerte. On veut peu de sons
  signalés, et la plupart des phrases sans aucune alerte.
- les autres groupes (« francophone ») n'ont pas de fautes notées : on compare, pour
  chaque faute visée (θ, jota, r, v), la part signalée à celle des natifs. Une faute de
  francophone doit sortir nettement plus souvent que chez les natifs.

    uv run python essais/prononciation/evaluer.py ~/common-voice-es/manifeste.tsv
"""
import collections
import csv
import json
import os
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)

from analyse import Analyseur  # noqa: E402
from entendre import charger_audio  # noqa: E402
from fautes import FAUTES, cibles  # noqa: E402


def main():
    manifeste = os.path.expanduser(sys.argv[1])
    dossier = os.path.dirname(manifeste)
    lignes = list(csv.DictReader(open(manifeste), delimiter="\t"))
    analyseur = Analyseur()

    notes = collections.defaultdict(collections.Counter)    # groupe → compteurs
    vises = collections.defaultdict(collections.Counter)    # (groupe, faute) → {vus, signalés}
    alertes = collections.defaultdict(collections.Counter)  # groupe → (attendu→variante, raison)
    locuteurs = collections.defaultdict(set)
    sortie = []
    for n, ligne in enumerate(lignes, 1):
        groupe = ligne.get("groupe") or "natif"
        try:
            r = analyseur.analyser(charger_audio(os.path.join(dossier, ligne["fichier"])), ligne["texte"])
        except ValueError as e:
            print(f"  ignoré {ligne['fichier']} : {e}")
            continue
        sortie.append({**ligne, **r})
        locuteurs[groupe].add(ligne.get("locuteur") or ligne["fichier"])
        notes_ph = [p for p in r["phonemes"] if p["score"] is not None]
        signales = [p for p in notes_ph if p["faute"]]
        notes[groupe].update(phrases=1, propres=not signales, phonemes=len(notes_ph), signales=len(signales))
        for p, faute in zip(r["phonemes"], cibles(r["mots"], r["phonemes"])):
            if faute and p["score"] is not None:
                vises[groupe, faute].update(vus=1, signales=p["faute"])
        for p in signales:
            alertes[groupe][f"{p['attendu']}→{p['variante']} ({p['raison']})"] += 1
        if n % 50 == 0:
            print(f"  {n}/{len(lignes)}")

    with open(os.path.join(dossier, "analyses.json"), "w") as f:
        json.dump(sortie, f, ensure_ascii=False)
    for groupe in sorted(notes, key=lambda g: g != "natif"):
        c = notes[groupe]
        print(f"\n== {groupe} : {c['phrases']} phrases, {len(locuteurs[groupe])} locuteurs")
        print(f"   sons signalés : {c['signales']}/{c['phonemes']} ({100 * c['signales'] / c['phonemes']:.1f} %),"
              f" phrases sans alerte : {c['propres']}/{c['phrases']}")
        for faute in FAUTES:
            v = vises[groupe, faute]
            if v["vus"]:
                print(f"   {faute:5} signalé {v['signales']:3}/{v['vus']:<4} ({100 * v['signales'] / v['vus']:4.0f} %)")
        print("   les plus fréquents :", ", ".join(f"{a} ×{k}" for a, k in alertes[groupe].most_common(8)))
    print(f"\nDétail : {os.path.join(dossier, 'analyses.json')}")


if __name__ == "__main__":
    main()
