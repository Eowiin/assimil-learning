"""Enregistre des phrases au micro du Mac et les analyse aussitôt.

Les phrases de test sont courtes, passées sans fausse faute par la voix native, et
riches en sons pièges pour un francophone (θ, jota, r/rr, v). Seules leurs
références sont ici : le texte est lu dans Resources/text, hors dépôt.

Deux prises par phrase :
  soigne   la meilleure prononciation possible ;
  fautes   chaque son piège fait exprès à la française, partout où il apparaît :
           θ (c, z) dit s, jota (j, ge, gi) dite r français, r et rr dits r français,
           v dit v (lèvre-dents). Le b reste un b.

Usage :
  essayer.py                          liste les phrases et les fautes à faire
  essayer.py --serie --essai soigne   enchaîne les 8 phrases (Entrée avant chaque prise)
  essayer.py N --essai fautes         une seule phrase
  essayer.py N --fichier AUDIO        analyse un enregistrement existant (iPhone…)
Options :
  --ecouter        fait d'abord écouter la voix native
  --micro NOM      micro avfoundation (défaut : Micro MacBook Pro)
  --marge S        secondes d'enregistrement en plus de la durée native (défaut : 2)

Enregistrements et analyses : calibration/voix/, hors dépôt. Le bilan : bilan.py.
"""
import argparse
import json
import os
import subprocess
import sys
import time

from analyse import Analyseur, afficher
from entendre import charger_audio
from phonemes import phonemiser

ICI = os.path.dirname(os.path.abspath(__file__))
RESSOURCES = os.path.join(ICI, "..", "..", "Resources")
VOIX = os.path.join(ICI, "calibration", "voix")

PHRASES = [
    ("L033", "S11.m4a"),
    ("L088", "S01.m4a"),
    ("L063", "S09.m4a"),
    ("L056", "S09.m4a"),
    ("L071", "S03.m4a"),
    ("L071", "S05.m4a"),
    ("L099", "S01.m4a"),
    ("L091", "S14.m4a"),
]
# Faute de francophone visée → (phonèmes attendus concernés, ce qu'on dit à la place).
FAUTES = {
    "θ": ({"θ"}, "s"),
    "jota": ({"x"}, "r français"),
    "r": ({"r", "ɾ"}, "r français"),
    "v": ({"b", "β"}, "v"),  # seulement là où la lettre est un v
}


def charger_phrase(lecon, fichier):
    """(texte, durée native) d'après le manifeste et le texte de la leçon."""
    manifeste = json.load(open(os.path.join(RESSOURCES, "manifest.json")))
    entree = next(l for l in manifeste["lessons"] if l["dir"] == lecon)
    piste = next(p for cle in ("dialogue", "exercise") for p in entree.get(cle, []) if p["file"] == fichier)
    texte = json.load(open(os.path.join(RESSOURCES, "text", lecon + ".json")))
    cle = "sentences" if fichier.startswith("S") else "exercise"
    es = next(p["es"] for p in texte[cle] if p["n"] == piste["n"])
    return es, piste["duration"]


def cibles(mots, phonemes):
    """Pour chaque phonème (dicts avec 'attendu' et 'mot'), la faute visée ou None.

    b et β ne sont visés que s'ils viennent d'un v : chaque b ou v écrit donne un
    seul b/β, dans l'ordre, ce qui permet de retrouver la lettre.
    """
    vus = {}
    sortie = []
    for p in phonemes:
        faute = next((nom for nom, (sons, _) in FAUTES.items() if p["attendu"] in sons), None)
        if faute == "v":
            lettres = [c for c in mots[p["mot"]] if c in "bv"]
            k = vus.get(p["mot"], 0)
            vus[p["mot"]] = k + 1
            faute = "v" if k < len(lettres) and lettres[k] == "v" else None
        sortie.append(faute)
    return sortie


def fautes_a_faire(es):
    """« jarra : jota, r ; favor : v, r »."""
    mots, sons, _ = phonemiser(es)
    phonemes = [{"attendu": s, "mot": i} for s, i in sons]
    par_mot = {}
    for p, faute in zip(phonemes, cibles(mots, phonemes)):
        if faute and faute not in par_mot.setdefault(p["mot"], []):
            par_mot[p["mot"]].append(faute)
    return " ; ".join(f"{mots[i]} : {', '.join(f)}" for i, f in par_mot.items())


def lister():
    print("Fautes : " + ", ".join(f"{nom} → {dit}" for nom, (_, dit) in FAUTES.items()) + "\n")
    for n, (lecon, fichier) in enumerate(PHRASES, 1):
        es, _ = charger_phrase(lecon, fichier)
        print(f"{n}. {es}\n   {fautes_a_faire(es)}")


def enregistrer(chemin, duree, micro):
    for k in (3, 2, 1):
        print(f"  {k}…", flush=True)
        time.sleep(1)
    print(f"  ● Parlez ({duree:.0f} s)", flush=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "avfoundation", "-i", f":{micro}",
                    "-t", f"{duree:.1f}", "-ac", "1", "-ar", "16000", chemin], check=True)
    print("  ■ Fin", flush=True)


def essayer(analyseur, n, a, chemin=None):
    """Enregistre (sauf si chemin est donné) puis analyse la phrase n."""
    lecon, fichier = PHRASES[n - 1]
    es, duree = charger_phrase(lecon, fichier)
    print(f"\n{n}. {es}")
    if a.essai == "fautes":
        print(f"   fautes à faire : {fautes_a_faire(es)}")
    os.makedirs(VOIX, exist_ok=True)
    base = f"{n:02d}-{lecon}-{fichier[:-4]}-{a.essai}-{time.strftime('%H%M%S')}"
    if chemin is None:
        if a.serie:
            if input("   Entrée pour enregistrer, s pour sauter : ").strip().lower() == "s":
                return
        if a.ecouter:
            subprocess.run(["afplay", os.path.join(RESSOURCES, "audio", lecon, fichier)], check=True)
        chemin = os.path.join(VOIX, base + ".wav")
        enregistrer(chemin, duree + a.marge, a.micro)

    resultat = analyseur.analyser(charger_audio(chemin), es)
    print()
    afficher(resultat)
    print(f"\n{sum(p['faute'] for p in resultat['phonemes'])} faute(s) signalée(s)")
    with open(os.path.join(VOIX, base + ".json"), "w") as f:
        json.dump({"phrase": n, "essai": a.essai, "audio": chemin, "horodatage": time.time(),
                   **resultat}, f, ensure_ascii=False)


def main():
    arguments = argparse.ArgumentParser()
    arguments.add_argument("n", type=int, nargs="?")
    arguments.add_argument("--serie", action="store_true")
    arguments.add_argument("--fichier")
    arguments.add_argument("--ecouter", action="store_true")
    arguments.add_argument("--essai", default="essai")
    arguments.add_argument("--micro", default="Micro MacBook Pro")
    arguments.add_argument("--marge", type=float, default=2.0)
    a = arguments.parse_args()
    if a.n is None and not a.serie:
        return lister()

    print("Chargement du modèle…", flush=True)
    analyseur = Analyseur()
    if a.serie:
        for n in range(1, len(PHRASES) + 1):
            while True:
                essayer(analyseur, n, a)
                if input("\n   Entrée : phrase suivante, r : refaire : ").strip().lower() != "r":
                    break
    else:
        essayer(analyseur, a.n, a, a.fichier)


if __name__ == "__main__":
    sys.exit(main())
