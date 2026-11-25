"""Seuils des deux jugements ZIPA (jota en r français, v dit [v]), tirés des voix natives.

Pour chaque /x/ et chaque /b/ écrit v des phrases natives, la part que ZIPA donne au son
fautif (`analyse.parts_zipa`) ; le seuil est le quantile 0,998 de ces parts, la même
exigence que les seuils GOP (quantile 0,002 des notes). Il ne regarde pas les prises du
test : il ne peut pas s'y ajuster.

Les natives sont les 1899 phrases d'Assimil préparées par spanish-pronunciation-coach
(manifest.jsonl : id, text, audio relatif à la racine de ce projet), hors dépôt.

    uv run python essais/prononciation/calibrer_zipa.py ~/projects/spanish-pronunciation-coach/data/assimil/manifest.jsonl
"""
import collections
import json
import os
import sys

import numpy as np

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ICI)

from analyse import SEUILS_ZIPA, ZIPA, parts_zipa  # noqa: E402
from app.prononciation.coach.acoustic import load_audio, load_model  # noqa: E402
from app.prononciation.coach.ctc import collapse  # noqa: E402
from app.prononciation.coach.g2p import transcribe  # noqa: E402

QUANTILE = 0.998


def main():
    manifeste = os.path.expanduser(sys.argv[1])
    racine = os.path.dirname(os.path.dirname(os.path.dirname(manifeste)))  # data/assimil/ → projet
    zipa = load_model(ZIPA)
    parts = collections.defaultdict(list)
    for n, ligne in enumerate(open(manifeste), 1):
        entree = json.loads(ligne)
        try:
            utt = transcribe(entree["text"])
        except ValueError:
            continue
        pp = collapse(zipa.posteriors(load_audio(os.path.join(racine, entree["audio"]))))
        for faute, part in parts_zipa(utt, pp).values():
            parts[faute].append(part)
        if n % 200 == 0:
            print(f"  {n} phrases")

    seuils = {}
    for faute, valeurs in sorted(parts.items()):
        v = np.array(valeurs)
        seuils[faute] = round(float(np.quantile(v, QUANTILE)), 3)
        print(f"{faute:5} {len(v):4} natifs : médiane {np.median(v):.3f}, q0,99 {np.quantile(v, 0.99):.3f},"
              f" max {v.max():.3f} → seuil {seuils[faute]}")
    with open(SEUILS_ZIPA, "w") as f:
        json.dump(seuils, f, indent=1)
        f.write("\n")
    print(f"→ {SEUILS_ZIPA}")


if __name__ == "__main__":
    main()
