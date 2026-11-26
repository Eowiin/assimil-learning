"""Les vrais modèles : Whisper pour écouter, un `LLM` pour écrire, un `TTS` pour parler.

Chargés une fois, au démarrage du serveur. Leur réglage passe par des variables
d'environnement, pour que rien de propre au PC (le chemin de la voix clonée, une
clé d'API) n'entre dans le dépôt public. L'IA et la voix sont chacune derrière un
protocole (`llm.py`, `voix.py`) : `Reels` ne fait que les assembler.
"""

from __future__ import annotations

import logging
import os
import subprocess
import unicodedata
from dataclasses import dataclass
from typing import Literal, TypeVar

from pydantic import BaseModel

from .llm import LLM, choisir_llm
from .voix import TTS, choisir_tts, en_m4a

M = TypeVar("M", bound=BaseModel)

journal = logging.getLogger("assimil")

# Comment écouter une prise (étape 6b) : l'espagnol imposé (A2 et au-delà), les deux
# langues (A0-A1, où l'on répond parfois en français), ou le français imposé (une
# demande « Je ne sais pas le dire »).
Ecoute = Literal["es", "bilingue", "fr"]

# L'amorce bilingue de l'essai du 2026-11-25 (`essais/crosstalk.py`, candidat
# `amorce`) : autant d'espagnol que l'espagnol imposé, et le français gardé en
# français au lieu d'être traduit. Sans mot des prises de l'essai.
AMORCE_BILINGUE = ("Un apprenant français parle espagnol et dit parfois quelques mots en "
                   "français. Necesito una… comment dire… une serviette, gracias.")


@dataclass(frozen=True)
class Reglages:
    whisper: str = "large-v3-turbo"
    appareil: str = "cuda"
    # À l'essai, désactivé tant qu'il n'est pas mesuré (`essais/whisper_contexte.py`) :
    # Whisper reçoit la dernière réplique de l'IA comme amorce.
    whisper_contexte: bool = False

    @classmethod
    def depuis_environnement(cls, env=os.environ) -> "Reglages":
        return cls(
            whisper=env.get("ASSIMIL_WHISPER", cls.whisper),
            appareil=env.get("ASSIMIL_APPAREIL", cls.appareil),
            whisper_contexte=env.get("ASSIMIL_WHISPER_CONTEXTE", "") == "1",
        )


def decoder_16k(audio: bytes):
    """N'importe quel audio vers du 16 kHz mono en flottants, par ffmpeg.
    faster-whisper sait lire un fichier seul, mais par PyAV, dont les versions
    récentes ne lui conviennent plus.

    L'audio passe par un fichier temporaire, pas par l'entrée de ffmpeg : un .m4a
    dont l'index (`moov`) est à la fin ne se lit pas d'un tube, et ffmpeg n'en
    rend alors rien, sans erreur (prises du Dictaphone, essai du 2026-11-25)."""
    import tempfile

    import numpy
    with tempfile.NamedTemporaryFile() as fichier:
        fichier.write(audio)
        fichier.flush()
        brut = subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", fichier.name,
             "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
            capture_output=True, check=True,
        ).stdout
    return numpy.frombuffer(brut, numpy.int16).astype(numpy.float32) / 32768.0


def transcrire(whisper, audio, amorce: str | None = None) -> str:
    """Whisper, l'espagnol imposé : sans ça, un accent français peut faire détecter
    du français. `amorce` (`initial_prompt`) : un texte que Whisper prend pour ce
    qui précède, et dont il reprend plus volontiers les mots. Partagé avec
    `essais/whisper_contexte.py`, pour mesurer exactement ce que fait le serveur."""
    segments, _ = whisper.transcribe(audio, language="es", beam_size=5, vad_filter=True,
                                     initial_prompt=amorce)
    return " ".join(s.text.strip() for s in segments).strip()


def transcrire_bilingue(whisper, audio) -> tuple[str, str]:
    """Whisper, la langue détectée morceau par morceau, avec l'amorce bilingue. Rend le
    texte et la langue détectée pour la prise (qui ne vaut rien seule : « fr » pour une
    prise mélangée, « ko » une fois à l'essai)."""
    segments, info = whisper.transcribe(audio, language=None, multilingual=True, beam_size=5,
                                        vad_filter=True, initial_prompt=AMORCE_BILINGUE)
    return " ".join(s.text.strip() for s in segments).strip(), info.language


def hors_latin(texte: str) -> bool:
    """Une lettre d'un autre alphabet que le latin : Whisper a cru entendre une langue
    qui n'est ni l'espagnol ni le français (du coréen, à l'essai)."""
    return any(c.isalpha() and not unicodedata.name(c, "").startswith("LATIN") for c in texte)


class Reels:
    """Les moteurs du serveur, tels que `conversation.Moteurs` les attend. Une seule IA
    écrit les répliques et le texte du bloc 2, et rend les jugements."""

    def __init__(self, reglages: Reglages, whisper, llm: LLM, tts: TTS):
        self.reglages = reglages
        self.whisper = whisper
        self.llm = llm
        self.tts = tts

    @classmethod
    def charger(cls, reglages: Reglages, env=os.environ) -> "Reels":
        from faster_whisper import WhisperModel

        calcul = "float16" if reglages.appareil == "cuda" else "int8"
        whisper = WhisperModel(reglages.whisper, device=reglages.appareil, compute_type=calcul)
        return cls(reglages, whisper, choisir_llm(env), choisir_tts(reglages.appareil, env))

    # --- Écouter --------------------------------------------------------------

    def ecouter(self, audio: bytes, contexte: str | None = None, langue: Ecoute = "es") -> str:
        echantillons = decoder_16k(audio)
        amorce = contexte if self.reglages.whisper_contexte and contexte else None
        if langue == "fr":
            segments, _ = self.whisper.transcribe(echantillons, language="fr", beam_size=5,
                                                  vad_filter=True)
            return " ".join(s.text.strip() for s in segments).strip()
        if langue == "bilingue":
            texte, detectee = transcrire_bilingue(self.whisper, echantillons)
            if not hors_latin(texte):
                return texte
            # Le filet : une autre langue que les deux attendues, on réécoute comme avant.
            journal.info("Écoute bilingue hors alphabet latin (%s) : l'espagnol imposé.", detectee)
        return transcrire(self.whisper, echantillons, amorce)

    # --- Penser ---------------------------------------------------------------

    def repondre(self, messages: list[dict]) -> str:
        return self.llm.chat(messages, temperature=0.7)

    def structurer(self, messages: list[dict], modele: type[M]) -> M:
        return self.llm.structured(messages, modele, temperature=0)

    def rediger(self, messages: list[dict], modele: type[M]) -> M:
        return self.llm.structured(messages, modele, temperature=0.7)

    # --- Parler ---------------------------------------------------------------

    def dire(self, texte: str) -> bytes:
        return en_m4a(self.tts.dire(texte))

    # --- Démarrage ------------------------------------------------------------

    def prechauffer(self) -> None:
        """Le premier passage sur la carte graphique prépare son code : 20 s au lieu
        d'une. On le fait au démarrage, pour ne jamais le subir en conversation.
        La voix et Whisper d'abord : si l'IA ne répond pas, ils sont déjà prêts."""
        self.ecouter(self.dire("Hola, ¿qué tal?"))
        self.llm.prechauffer()
