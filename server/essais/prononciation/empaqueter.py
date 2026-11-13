"""Sur le Mac : rassemble les prises du test du 10 novembre 2026 dans un dossier à
copier sur le PC, avec le texte de chaque phrase.

Les prises (tools/prononciation/calibration/voix) et le texte d'Assimil
(Resources/text) sont hors dépôt : le dossier produit l'est aussi.

    python3 server/essais/prononciation/empaqueter.py ~/Desktop/prises-10-novembre
"""
import glob
import json
import os
import shutil
import sys

RACINE = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
VOIX = os.path.join(RACINE, "tools", "prononciation", "calibration", "voix")
TEXTE = os.path.join(RACINE, "Resources", "text")
MANIFESTE = os.path.join(RACINE, "Resources", "manifest.json")

# Les références des 8 phrases du test, dans l'ordre (essayer.py, même branche).
PHRASES = [("L033", "S11.m4a"), ("L088", "S01.m4a"), ("L063", "S09.m4a"), ("L056", "S09.m4a"),
           ("L071", "S03.m4a"), ("L071", "S05.m4a"), ("L099", "S01.m4a"), ("L091", "S14.m4a")]


def texte(lecon, fichier):
    manifeste = json.load(open(MANIFESTE))
    entree = next(l for l in manifeste["lessons"] if l["dir"] == lecon)
    piste = next(p for cle in ("dialogue", "exercise") for p in entree.get(cle, []) if p["file"] == fichier)
    lecon_texte = json.load(open(os.path.join(TEXTE, lecon + ".json")))
    cle = "sentences" if fichier.startswith("S") else "exercise"
    return next(p["es"] for p in lecon_texte[cle] if p["n"] == piste["n"])


def main():
    destination = os.path.expanduser(sys.argv[1])
    os.makedirs(destination, exist_ok=True)
    for chemin in sorted(glob.glob(os.path.join(VOIX, "*.json"))):
        prise = json.load(open(chemin))
        wav = os.path.join(VOIX, os.path.basename(prise["audio"]))
        prise["texte"] = texte(*PHRASES[prise["phrase"] - 1])
        prise["audio"] = os.path.basename(wav)
        shutil.copy(wav, destination)
        with open(os.path.join(destination, os.path.basename(chemin)), "w") as f:
            json.dump(prise, f, ensure_ascii=False)
    print(f"{len(glob.glob(os.path.join(destination, '*.wav')))} prises dans {destination}")


if __name__ == "__main__":
    main()
