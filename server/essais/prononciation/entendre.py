"""Transcrit un enregistrement en phonèmes, sans le corriger vers un texte attendu.

Usage : entendre.py FICHIER_AUDIO [...]
"""
import os
import sys

from coach.acoustic import MODELS, load_audio, load_model
from coach.ctc import greedy_decode

# Le modèle phonétique, parmi ceux dont les seuils GOP sont calibrés sur les natifs
# (coach/thresholds/gop_<nom>.json) : xlsr53 (le défaut, celui du 10 novembre), lv60, cnam.
MODELE = os.environ.get("ASSIMIL_PRONONCIATION_MODELE", "xlsr53")
charger_audio = load_audio


def main():
    modele = load_model(MODELE)
    print(f"Modèle : {MODELE} ({MODELS[MODELE][1]})")
    for chemin in sys.argv[1:]:
        post = modele.posteriors(charger_audio(chemin))
        print(f"{chemin}\n  {' '.join(s.symbol for s in greedy_decode(post.log_probs, post.vocab, post.blank))}")


if __name__ == "__main__":
    main()
