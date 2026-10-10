"""Passe l'analyse sur toutes les phrases natives et résume où le modèle se trompe seul.

Une voix native est censée être juste partout : chaque score négatif est une
fausse alerte, du modèle ou de la conversion texte → phonèmes. Le résumé dit,
par phonème attendu, combien de fois il est contesté et par quoi.

Le seuil d'un phonème est le score que seules QUANTILE des occurrences natives
n'atteignent pas (jamais au-dessus de 0) : écrit dans seuils.json, que lit l'analyse.

Usage : calibrer.py [SORTIE.jsonl]  (relance : les phrases déjà notées sont sautées)
Le fichier de sortie contient du texte Assimil : il reste hors dépôt (calibration/).
"""
import collections
import json
import os
import sys

from analyse import SEUILS, Analyseur
from entendre import charger_audio

RACINE = os.path.join(os.path.dirname(__file__), "..", "..", "Resources")
QUANTILE = 0.02


def phrases_natives():
    """(clé, audio, texte) pour titres, dialogues et exercices ayant un texte."""
    manifeste = json.load(open(os.path.join(RACINE, "manifest.json")))
    for lecon in manifeste["lessons"]:
        chemin = os.path.join(RACINE, "text", lecon["dir"] + ".json")
        if not os.path.exists(chemin):
            continue
        texte = json.load(open(chemin))
        sources = [("title", [lecon["title"]] if lecon.get("title") else [], {None: texte.get("titleES")})]
        for cle in ("dialogue", "exercise"):
            phrases = texte.get("sentences" if cle == "dialogue" else "exercise", [])
            sources.append((cle, lecon.get(cle, []), {p["n"]: p["es"] for p in phrases}))
        for cle, fichiers, textes in sources:
            for f in fichiers:
                es = textes.get(f.get("n"))
                if es:
                    yield (f"{lecon['dir']}/{f['file']}",
                           os.path.join(RACINE, "audio", lecon["dir"], f["file"]), es)


def calibrer(sortie):
    faites = set()
    if os.path.exists(sortie):
        faites = {json.loads(l)["cle"] for l in open(sortie)}
    analyseur = Analyseur()
    ignorees = 0
    with open(sortie, "a") as f:
        for cle, audio, es in phrases_natives():
            if cle in faites:
                continue
            try:
                resultat = analyseur.analyser(charger_audio(audio), es)
            except ValueError:
                ignorees += 1
                continue
            f.write(json.dumps({"cle": cle, "texte": es, **resultat}, ensure_ascii=False) + "\n")
            f.flush()
    print(f"{ignorees} phrases ignorées (nombres)", file=sys.stderr)


def resumer(sortie):
    """Écrit les seuils et affiche, par phonème, les contestations natives (score ≤ 0)."""
    scores, variantes = collections.defaultdict(list), collections.defaultdict(collections.Counter)
    phrases = [json.loads(l) for l in open(sortie)]
    for phrase in phrases:
        for p in phrase["phonemes"]:
            scores[p["attendu"]].append(p["score"])
            if p["score"] <= 0:
                variantes[p["attendu"]][p["variante"]] += 1
    seuils = {p: min(0.0, sorted(s)[int(QUANTILE * len(s))]) for p, s in scores.items()}
    with open(SEUILS, "w") as f:
        json.dump(dict(sorted(seuils.items())), f, ensure_ascii=False, indent=2)

    n = sum(len(s) for s in scores.values())
    contestes = sum(1 for s in scores.values() for x in s if x <= 0)
    print(f"{len(phrases)} phrases, {n} phonèmes, {contestes} contestés ({100 * contestes / n:.1f} %)\n")
    print(f"{'attendu':8} {'total':>6} {'contesté':>9} {'seuil':>6}   entendu à la place")
    for p, s in sorted(scores.items(), key=lambda e: -len(e[1])):
        taux = 100 * sum(1 for x in s if x <= 0) / len(s)
        detail = ", ".join(f"{q} {c}" for q, c in variantes[p].most_common(4))
        print(f"{p:8} {len(s):6} {taux:8.1f} % {seuils[p]:6.1f}   {detail}")


if __name__ == "__main__":
    sortie = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "calibration", "natif.jsonl")
    os.makedirs(os.path.dirname(sortie), exist_ok=True)
    calibrer(sortie)
    resumer(sortie)
