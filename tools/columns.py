#!/usr/bin/env python3
"""
Recompose les colonnes d'une page Assimil à partir de la sortie OCR.

Une page Assimil est en deux colonnes : espagnol et notes à gauche, français et
corrigés à droite. Vision restitue les lignes dans un ordre de lecture approximatif
qui entrelace les deux, ce qui rend le texte brut difficile à relire. On se sert
donc de la position horizontale pour les séparer avant toute transcription.

    python3 tools/columns.py L001 [L002 ...]
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OCR = ROOT / "content" / "ocr"

# Frontière entre les deux colonnes, en largeur de page normalisée.
SPLIT = 0.50


def render(name: str) -> None:
    path = OCR / f"{name}.json"
    if not path.exists():
        print(f"{name} : pas de sortie OCR ({path})", file=sys.stderr)
        return

    doc = json.loads(path.read_text())
    for page in doc["pages"]:
        left = sorted((l for l in page["lines"] if l["x"] < SPLIT), key=lambda l: l["y"])
        right = sorted((l for l in page["lines"] if l["x"] >= SPLIT), key=lambda l: l["y"])

        print(f"\n{'=' * 70}")
        print(f"{name} — page {page['index'] + 1}")
        print("=" * 70)
        for label, column in (("COLONNE GAUCHE", left), ("COLONNE DROITE", right)):
            print(f"\n--- {label} ---")
            for line in column:
                # La confiance signale les lignes à relire en priorité.
                flag = "  ⚠" if line["confidence"] < 0.5 else ""
                print(f"{line['text']}{flag}")


if __name__ == "__main__":
    names = sys.argv[1:] or [p.stem for p in sorted(OCR.glob("L*.json"))]
    for n in names:
        render(n)
