"""Les vrais modèles : Whisper, l'IA par Ollama, et XTTS v2.

Chargés une fois, au démarrage du serveur, puis gardés en mémoire graphique. Leur
réglage passe par des variables d'environnement, pour que rien de propre au PC
(le chemin de la voix clonée, notamment) n'entre dans le dépôt public.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

import httpx

from .conversation import Corrections


@dataclass(frozen=True)
class Reglages:
    ia: str = "qwen3:8b"
    whisper: str = "large-v3-turbo"
    appareil: str = "cuda"
    ollama: str = "http://localhost:11434"
    # Un extrait de 6 à 15 s de la voix à imiter. Sans lui, une voix fournie avec XTTS.
    voix: Path | None = None
    locuteur: str = "Ana Florence"
    # Combien de temps Ollama garde l'IA en mémoire après le dernier tour.
    garder_ia: str = "30m"

    @classmethod
    def depuis_environnement(cls) -> "Reglages":
        env = os.environ.get
        voix = env("ASSIMIL_VOIX")
        return cls(
            ia=env("ASSIMIL_IA", cls.ia),
            whisper=env("ASSIMIL_WHISPER", cls.whisper),
            appareil=env("ASSIMIL_APPAREIL", cls.appareil),
            ollama=env("OLLAMA_HOST_URL", cls.ollama),
            voix=Path(voix).expanduser() if voix else None,
            locuteur=env("ASSIMIL_LOCUTEUR", cls.locuteur),
            garder_ia=env("ASSIMIL_GARDER_IA", cls.garder_ia),
        )


class OllamaIndisponible(RuntimeError):
    pass


def decoder_16k(audio: bytes):
    """N'importe quel audio vers du 16 kHz mono en flottants, par ffmpeg.
    faster-whisper sait lire un fichier seul, mais par PyAV, dont les versions
    récentes ne lui conviennent plus."""
    import numpy
    brut = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", "pipe:0",
         "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
        input=audio, capture_output=True, check=True,
    ).stdout
    return numpy.frombuffer(brut, numpy.int16).astype(numpy.float32) / 32768.0


def encoder_aac(wav: Path) -> bytes:
    """Le WAV de XTTS en AAC : une réponse de 4 s passe de 190 à environ 40 Ko.
    Le conteneur MP4 a besoin d'un fichier, pas d'un flux."""
    with tempfile.TemporaryDirectory() as dossier:
        sortie = Path(dossier) / "reponse.m4a"
        subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(wav),
             "-c:a", "aac", "-b:a", "64k", "-ac", "1", str(sortie)],
            check=True, capture_output=True,
        )
        return sortie.read_bytes()


class Reels:
    def __init__(self, reglages: Reglages):
        from faster_whisper import WhisperModel
        from TTS.api import TTS

        self.reglages = reglages
        calcul = "float16" if reglages.appareil == "cuda" else "int8"
        self.whisper = WhisperModel(reglages.whisper, device=reglages.appareil, compute_type=calcul)
        self.tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(reglages.appareil)
        if reglages.voix and not reglages.voix.exists():
            raise FileNotFoundError(f"ASSIMIL_VOIX : {reglages.voix} introuvable")
        self.ollama = httpx.Client(base_url=reglages.ollama, timeout=120)

    # --- Écouter --------------------------------------------------------------

    def ecouter(self, audio: bytes) -> str:
        segments, _ = self.whisper.transcribe(decoder_16k(audio), language="es", beam_size=5,
                                              vad_filter=True)
        return " ".join(s.text.strip() for s in segments).strip()

    # --- Penser ---------------------------------------------------------------

    def _chat(self, messages: list[dict], **extra) -> str:
        corps = {"model": self.reglages.ia, "messages": messages, "stream": False,
                 "keep_alive": self.reglages.garder_ia, **extra}
        # Qwen3 réfléchit avant de répondre : utile pour un problème, trop lent pour
        # une conversation.
        if self.reglages.ia.startswith("qwen3"):
            corps["think"] = False
        try:
            reponse = self.ollama.post("/api/chat", json=corps)
            reponse.raise_for_status()
        except httpx.HTTPError as erreur:
            raise OllamaIndisponible(str(erreur)) from erreur
        return reponse.json()["message"]["content"].strip()

    def repondre(self, messages: list[dict]) -> str:
        return self._chat(messages, options={"temperature": 0.7})

    def corriger(self, messages: list[dict]) -> Corrections:
        # Sortie structurée d'Ollama : la réponse suit le schéma, pas besoin de la
        # découper à la main.
        texte = self._chat(messages, format=Corrections.model_json_schema(),
                           options={"temperature": 0})
        return Corrections.model_validate_json(texte)

    # --- Parler ---------------------------------------------------------------

    def dire(self, texte: str) -> bytes:
        with tempfile.TemporaryDirectory() as dossier:
            wav = Path(dossier) / "reponse.wav"
            if self.reglages.voix:
                self.tts.tts_to_file(text=texte, speaker_wav=str(self.reglages.voix),
                                     language="es", file_path=str(wav))
            else:
                self.tts.tts_to_file(text=texte, speaker=self.reglages.locuteur,
                                     language="es", file_path=str(wav))
            return encoder_aac(wav)

    # --- Démarrage ------------------------------------------------------------

    def prechauffer(self) -> None:
        """Le premier passage sur la carte graphique prépare son code : 20 s au lieu
        d'une. On le fait au démarrage, pour ne jamais le subir en conversation."""
        audio = self.dire("Hola, ¿qué tal?")
        self.ecouter(audio)
        self.repondre([{"role": "user", "content": "Hola"}])
