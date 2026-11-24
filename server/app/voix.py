"""La voix de l'IA : un moteur de synthèse derrière le protocole `TTS`.

Un moteur rend un `Audio` dans son propre format (le WAV de XTTS, de Pocket ou de
Voxtral). Rien n'est converti ici : la conversation et `/tts`, dont l'app range
chaque phrase dans un fichier .m4a, passent par `en_m4a`, qui ne touche pas à un
audio déjà en m4a.

Le choix se fait par `ASSIMIL_TTS` (étape 5c) :
- `voxtral` (par défaut) : la voix de Mistral, par son API, avec Pocket TTS en
  secours sur le PC si Mistral échoue, tarde ou que le PC est hors ligne
  (`ASSIMIL_TTS_SECOURS=aucun` pour s'en passer) ;
- `pocket` : Pocket TTS seul, en local ;
- `xtts` : XTTS v2 sur la carte graphique, la voix d'avant.
Phonon (Gradium) a été écarté : sa licence (CC BY-NC) interdirait de sortir l'app.
"""

from __future__ import annotations

import base64
import io
import logging
import os
import subprocess
import tempfile
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

import httpx

journal = logging.getLogger("assimil")


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


class VoixIndisponible(RuntimeError):
    """Une voix en ligne ne répond pas, ou refuse la phrase."""


def ralentir(audio: Audio, vitesse: float) -> Audio:
    """L'audio joué à `vitesse` (0,9 : 10 % plus lent), sans changer la hauteur de la
    voix (`atempo` de ffmpeg). Rend un WAV."""
    if vitesse == 1:
        return audio
    if not 0.5 <= vitesse <= 2:
        raise ValueError(f"Vitesse de la voix hors de 0,5 à 2 : {vitesse}")
    with tempfile.TemporaryDirectory() as dossier:
        entree = Path(dossier) / f"voix.{audio.format}"
        sortie = Path(dossier) / "lent.wav"
        entree.write_bytes(audio.donnees)
        subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(entree),
             "-filter:a", f"atempo={vitesse}", str(sortie)],
            check=True, capture_output=True,
        )
        return Audio(sortie.read_bytes(), "wav")


class VoxtralTTS:
    """Voxtral, la voix de Mistral, par son API (`/v1/audio/speech`). La clé est celle
    de l'IA (`MISTRAL_API_KEY`). Elena (`voice_483`) est la voix espagnole fournie.
    Le WAV est demandé plutôt que le mp3 : l'app reçoit de l'AAC, et passer par le mp3
    compresserait deux fois.

    Elena parle vite pour un apprenant (essai du 2026-11-24) : sa voix est ralentie à
    `vitesse` (0,9 par défaut), hauteur gardée. Le 0,85 des débutants, joué par l'app,
    s'y ajoute."""

    def __init__(self, cle: str, modele: str = "voxtral-mini-tts-3-0", voix: str = "voice_483",
                 delai: float = 10, vitesse: float = 0.9, url: str = "https://api.mistral.ai",
                 client: httpx.Client | None = None):
        if not cle:
            raise ValueError("La voix Voxtral demande la clé de Mistral dans MISTRAL_API_KEY.")
        if not 0.5 <= vitesse <= 2:
            raise ValueError(f"ASSIMIL_VOXTRAL_VITESSE={vitesse} : choisir entre 0,5 et 2.")
        self.modele = modele
        self.voix = voix
        self.vitesse = vitesse
        self.client = client or httpx.Client(base_url=url, timeout=delai)
        self.client.headers["Authorization"] = f"Bearer {cle}"
        self.nom = f"voxtral {voix}"

    def dire(self, texte: str) -> Audio:
        corps = {"model": self.modele, "input": texte, "voice_id": self.voix, "response_format": "wav"}
        try:
            reponse = self.client.post("/v1/audio/speech", json=corps)
            reponse.raise_for_status()
            audio = Audio(base64.b64decode(reponse.json()["audio_data"]), "wav")
        except httpx.HTTPStatusError as erreur:
            raise VoixIndisponible(f"Voxtral répond {erreur.response.status_code}.") from erreur
        except httpx.HTTPError as erreur:
            raise VoixIndisponible("Voxtral ne répond pas : le PC a-t-il accès à internet ?") from erreur
        except (KeyError, ValueError) as erreur:
            raise VoixIndisponible("Voxtral a rendu une réponse sans audio.") from erreur
        return ralentir(audio, self.vitesse)


def wav_16_bits(echantillons, frequence: int) -> bytes:
    """Des échantillons flottants (-1 à 1) en WAV 16 bits mono, sans scipy."""
    import numpy

    entiers = (numpy.clip(numpy.asarray(echantillons, dtype=numpy.float32), -1, 1) * 32767).astype("<i2")
    tampon = io.BytesIO()
    with wave.open(tampon, "wb") as sortie:
        sortie.setnchannels(1)
        sortie.setsampwidth(2)
        sortie.setframerate(frequence)
        sortie.writeframes(entiers.tobytes())
    return tampon.getvalue()


class PocketTTS:
    """Pocket TTS (Kyutai) : 100 M de paramètres, plus vite que le temps réel sur un
    processeur. `langue` : `spanish`, ou `spanish_24l`, plus fin mais plus lent (en
    préversion). Lola est sa seule voix espagnole. Connu pour couper les phrases très
    courtes (issue #174 du projet) : c'est la voix de secours, pas la principale."""

    def __init__(self, langue: str = "spanish", voix: str = "lola", appareil: str = "cpu"):
        from pocket_tts import TTSModel

        self.modele = TTSModel.load_model(language=langue)
        if appareil != "cpu":
            self.modele = self.modele.to(appareil)
        self.etat = self.modele.get_state_for_audio_prompt(voix)
        self.nom = f"pocket {langue} {voix}"

    def dire(self, texte: str) -> Audio:
        audio = self.modele.generate_audio(self.etat, texte)
        return Audio(wav_16_bits(audio.detach().cpu().numpy(), self.modele.sample_rate), "wav")


class TTSAvecSecours:
    """Une voix principale (en ligne) et une de secours (locale). Après un échec, la
    principale est laissée de côté `pause` secondes : hors ligne, chaque phrase
    attendrait sinon le délai entier avant de passer au secours."""

    def __init__(self, principal: TTS, secours: TTS, pause: float = 60, horloge=time.monotonic):
        self.principal = principal
        self.secours = secours
        self.pause = pause
        self.horloge = horloge
        self.reprise = 0.0
        self.nom = f"{principal.nom}, secours {secours.nom}"

    def dire(self, texte: str) -> Audio:
        if self.horloge() >= self.reprise:
            try:
                return self.principal.dire(texte)
            except Exception as erreur:  # noqa: BLE001 — toute panne passe au secours
                journal.warning("Voix %s en échec (%s) : %s prend le relais %.0f s.",
                                self.principal.nom, erreur, self.secours.nom, self.pause)
                self.reprise = self.horloge() + self.pause
        return self.secours.dire(texte)


TTS_ECRITS = ("voxtral", "pocket", "xtts")


def _pocket(appareil: str, env) -> PocketTTS:
    """Sur le processeur par défaut : Kyutai ne le prévoit que là, il y va plus vite que
    le temps réel, et la carte graphique reste à Whisper et à la prononciation.
    `ASSIMIL_POCKET_APPAREIL=cuda` pour essayer la carte."""
    return PocketTTS(langue=env.get("ASSIMIL_POCKET_LANGUE", "spanish"),
                     voix=env.get("ASSIMIL_POCKET_VOIX", "lola"),
                     appareil=env.get("ASSIMIL_POCKET_APPAREIL", "cpu"))


def choisir_tts(appareil: str = "cuda", env=os.environ, pocket=_pocket) -> TTS:
    """La voix choisie par `ASSIMIL_TTS`, réglée par les variables d'environnement.
    `pocket` construit la voix locale : les tests en passent une fausse."""
    choix = env.get("ASSIMIL_TTS", "voxtral").strip().lower()
    if choix == "voxtral":
        voxtral = VoxtralTTS(cle=env.get("MISTRAL_API_KEY", ""),
                             voix=env.get("ASSIMIL_VOXTRAL_VOIX", "voice_483"),
                             delai=float(env.get("ASSIMIL_VOXTRAL_DELAI", "10")),
                             vitesse=float(env.get("ASSIMIL_VOXTRAL_VITESSE", "0.9")))
        if env.get("ASSIMIL_TTS_SECOURS", "pocket").strip().lower() == "aucun":
            return voxtral
        return TTSAvecSecours(voxtral, pocket(appareil, env))
    if choix == "pocket":
        return pocket(appareil, env)
    if choix == "xtts":
        voix = env.get("ASSIMIL_VOIX")
        return XTTSLocal(appareil=appareil, voix=Path(voix).expanduser() if voix else None,
                         locuteur=env.get("ASSIMIL_LOCUTEUR", "Ana Florence"))
    raise ValueError(f"ASSIMIL_TTS={choix} : choisir parmi {', '.join(TTS_ECRITS)}.")
