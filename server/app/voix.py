"""La voix de l'IA : un moteur de synthèse derrière le protocole `TTS`.

Un moteur rend un `Audio` dans son propre format (le WAV de XTTS, le mp3 ou l'opus
d'une voix en ligne). Rien n'est converti ici : seule la conversation, dont l'app
range la réplique dans un fichier .m4a, passe par `en_m4a`, qui ne touche pas à
un audio déjà en m4a. Le choix se fait par `ASSIMIL_TTS` : `xtts` aujourd'hui ;
`pocket`, `phonon` et `voxtral` ont leur nom réservé, pas encore leur code.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class Audio:
    donnees: bytes
    # L'extension, sans point : « wav », « m4a », « mp3 », « opus »…
    format: str


class TTS(Protocol):
    # Ce que le journal affiche au démarrage.
    nom: str

    def dire(self, texte: str) -> Audio:
        """Le texte, en espagnol, à voix haute."""
        ...


def en_m4a(audio: Audio) -> bytes:
    """L'audio en AAC (.m4a), ce que l'app joue en conversation. Une réponse de 4 s
    passe de 190 Ko en WAV à environ 40 Ko. Le conteneur MP4 a besoin d'un
    fichier, pas d'un flux : ffmpeg écrit dans un dossier temporaire."""
    if audio.format == "m4a":
        return audio.donnees
    with tempfile.TemporaryDirectory() as dossier:
        entree = Path(dossier) / f"voix.{audio.format}"
        sortie = Path(dossier) / "voix.m4a"
        entree.write_bytes(audio.donnees)
        subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(entree),
             "-c:a", "aac", "-b:a", "64k", "-ac", "1", str(sortie)],
            check=True, capture_output=True,
        )
        return sortie.read_bytes()


class XTTSLocal:
    """XTTS v2 sur la carte graphique, tel qu'avant. Il imite la voix de l'extrait
    `voix` (6 à 15 s) ; sans lui, il prend une voix fournie, `locuteur`."""

    def __init__(self, appareil: str = "cuda", voix: Path | None = None,
                 locuteur: str = "Ana Florence"):
        from TTS.api import TTS as Coqui

        if voix and not voix.exists():
            raise FileNotFoundError(f"ASSIMIL_VOIX : {voix} introuvable")
        self.voix = voix
        self.locuteur = locuteur
        self.modele = Coqui("tts_models/multilingual/multi-dataset/xtts_v2").to(appareil)
        self.nom = f"xtts {voix.name if voix else locuteur}"

    def dire(self, texte: str) -> Audio:
        with tempfile.TemporaryDirectory() as dossier:
            wav = Path(dossier) / "voix.wav"
            if self.voix:
                self.modele.tts_to_file(text=texte, speaker_wav=str(self.voix),
                                        language="es", file_path=str(wav))
            else:
                self.modele.tts_to_file(text=texte, speaker=self.locuteur,
                                        language="es", file_path=str(wav))
            return Audio(wav.read_bytes(), "wav")


TTS_ECRITS = ("xtts",)
TTS_PREVUS = ("pocket", "phonon", "voxtral")


def choisir_tts(appareil: str = "cuda", env=os.environ) -> TTS:
    """La voix choisie par `ASSIMIL_TTS`, réglée par les variables d'environnement."""
    choix = env.get("ASSIMIL_TTS", "xtts").strip().lower()
    if choix == "xtts":
        voix = env.get("ASSIMIL_VOIX")
        return XTTSLocal(appareil=appareil, voix=Path(voix).expanduser() if voix else None,
                         locuteur=env.get("ASSIMIL_LOCUTEUR", "Ana Florence"))
    if choix in TTS_PREVUS:
        raise ValueError(f"ASSIMIL_TTS={choix} : prévu, pas encore écrit. Pour l'instant : xtts.")
    raise ValueError(f"ASSIMIL_TTS={choix} : choisir parmi {', '.join(TTS_ECRITS)}.")
