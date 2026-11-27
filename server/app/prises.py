"""Garder les vraies prises des débutants, pour l'essai du crosstalk.

En conversation, Whisper réécrit parfois une prise mélangée tout en espagnol ou tout
en français. Les 20 prises lues de l'essai (`essais/crosstalk.py`) ne le montrent
pas : il faut les vraies. Si `ASSIMIL_GARDER_PRISES` nomme un dossier, chaque prise
écoutée dans les deux langues (A0, A1) y est rangée, au format de l'essai :
`01.m4a`, `02.m4a`… et, dans `entendu.json`, ce que le serveur a compris.

Rien ne sort du PC, et sans la variable, rien n'est gardé. Pour s'en servir, voir
`essais/README.md`.
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

journal = logging.getLogger("uvicorn.error")


class Carnet:
    def __init__(self, dossier: Path):
        self.dossier = dossier

    @classmethod
    def depuis_environnement(cls, env=os.environ) -> "Carnet | None":
        dossier = env.get("ASSIMIL_GARDER_PRISES", "").strip()
        return cls(Path(dossier).expanduser()) if dossier else None

    @property
    def index(self) -> Path:
        return self.dossier / "entendu.json"

    def garder(self, audio: bytes, nom_fichier: str | None, entendu: str,
               replique: str | None = None) -> int | None:
        """Range la prise et rend son numéro, ou rien si l'écriture échoue : une prise
        qui ne se garde pas ne fait pas échouer le tour."""
        try:
            self.dossier.mkdir(parents=True, exist_ok=True)
            notes = json.loads(self.index.read_text()) if self.index.exists() else {}
            numero = max((int(n) for n in notes), default=0) + 1
            extension = Path(nom_fichier or "").suffix or ".m4a"
            (self.dossier / f"{numero:02d}{extension}").write_bytes(audio)
            notes[str(numero)] = {"entendu": entendu, "replique": replique,
                                  "date": time.strftime("%Y-%m-%d %H:%M")}
            self.index.write_text(json.dumps(notes, ensure_ascii=False, indent=2))
            return numero
        except (OSError, ValueError) as erreur:
            journal.warning("Prise non gardée : %s", erreur)
            return None
