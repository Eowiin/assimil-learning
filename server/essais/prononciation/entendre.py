"""Transcrit un enregistrement en phonèmes, sans le corriger vers un texte attendu.

Usage : entendre.py FICHIER_AUDIO [...]
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from app.prononciation.analyse import MODELE  # noqa: E402
from app.prononciation.coach.acoustic import MODELS, load_audio, load_model  # noqa: E402
from app.prononciation.coach.ctc import greedy_decode  # noqa: E402

charger_audio = load_audio


def main():
    modele = load_model(MODELE)
    print(f"Modèle : {MODELE} ({MODELS[MODELE][1]})")
    for chemin in sys.argv[1:]:
        post = modele.posteriors(charger_audio(chemin))
        print(f"{chemin}\n  {' '.join(s.symbol for s in greedy_decode(post.log_probs, post.vocab, post.blank))}")


if __name__ == "__main__":
    main()
