"""Le serveur de la maison.

L'app l'interroge par Tailscale. Le serveur ne garde rien de l'apprenant :
l'iPhone envoie à chaque échange ce qu'il faut, et range lui-même ce qui revient
(cadrage v2, décision 2).
"""

from __future__ import annotations

import base64
import logging
import shutil
import subprocess
import threading
import time
from contextlib import asynccontextmanager
from functools import lru_cache

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

from .conversation import (Correction, Message, Moteurs, Profil, derniere_replique, messages_correction,
                           messages_ouverture, messages_tour)
from .moteurs import OllamaIndisponible
from .prononciation.jugement import par_mots

VERSION = "0.2.0"
# Monte quand une route change de forme : l'app saura qu'elle parle à un serveur
# trop ancien ou trop récent pour elle. Ajouter une route ne la fait pas monter :
# `modules` dit ce qui est prêt.
API_VERSION = 1

# Le journal de uvicorn : ses messages sortent dans le terminal du serveur, sans réglage.
journal = logging.getLogger("uvicorn.error")


class Health(BaseModel):
    status: str
    version: str
    api: int
    gpu: str | None
    modules: list[str]


class Timings(BaseModel):
    """Le temps de chaque étape, en secondes."""
    listen: float | None = None
    think: float
    speak: float


class Reply(BaseModel):
    """Une réplique de l'IA. `audio` est un .m4a (AAC) en base64."""
    reply: str
    audio: str
    timings: Timings


class Turn(Reply):
    heard: str


class StartRequest(BaseModel):
    topic: str | None = None
    profile: Profil | None = None


class ReviewRequest(BaseModel):
    history: list[Message]


class Review(BaseModel):
    corrections: list[Correction]


class Phone(BaseModel):
    """Un son attendu, jugé. `heard` : ce qui a été entendu à la place, pour une faute
    ou un indice. `reason` : qui l'a repéré (gop, r, zipa). `hint` : un simple indice
    (le r roulé dit battu, que beaucoup de natifs font), pas une faute. `start` et
    `end` : sa place dans l'audio, en secondes. Un son non noté (mot étranger, sigle)
    a `score` à null."""
    expected: str
    heard: str | None
    fault: bool
    reason: str | None
    hint: bool
    tip: str | None
    score: float | None
    threshold: float | None
    start: float | None
    end: float | None


class Word(BaseModel):
    text: str
    fault: bool
    phonemes: list[Phone]


class Pronunciation(BaseModel):
    """Le jugement d'une phrase. `heard` : les sons reconnus, sans la phrase attendue."""
    words: list[Word]
    heard: str
    seconds: float


DUREE_MIN = 0.3  # secondes d'audio : en dessous, rien à juger


@lru_cache(maxsize=1)
def gpu_name() -> str | None:
    """Le nom de la carte graphique, si `nvidia-smi` répond. Sous WSL2, il est
    fourni par le pilote Windows. Lu une fois : la carte ne change pas en route."""
    if shutil.which("nvidia-smi") is None:
        return None
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    first = out.strip().splitlines()
    return first[0].strip() if first else None


def charger_moteurs() -> Moteurs:
    """Les vrais modèles, chargés et préchauffés. Importés ici seulement : les tests
    n'ont pas à tirer PyTorch."""
    from .moteurs import Reels, Reglages

    reglages = Reglages.depuis_environnement()
    journal.info("Chargement des modèles (IA %s, Whisper %s, voix %s)…", reglages.ia,
                 reglages.whisper, reglages.voix or reglages.locuteur)
    moteurs = Reels(reglages)
    debut = time.perf_counter()
    try:
        moteurs.prechauffer()
        journal.info("Tour à vide fait en %.1f s.", time.perf_counter() - debut)
    except OllamaIndisponible as erreur:
        journal.warning("Ollama ne répond pas (%s) : la conversation attendra qu'il soit lancé.", erreur)
    return moteurs


def charger_prononciation():
    """Les deux modèles phonétiques (wav2vec2 sur la carte, ZIPA sur le processeur).
    S'ils manquent, la conversation tourne quand même."""
    from .prononciation.analyse import MODELE, Analyseur

    journal.info("Chargement de la prononciation (%s et ZIPA)…", MODELE)
    try:
        analyseur = Analyseur()
        # Le premier passage sur la carte est lent : fait ici, pas sur la première phrase.
        import numpy
        analyseur.analyser(numpy.zeros(16000, numpy.float32), "Hola")
        return analyseur
    except Exception:
        journal.exception("La prononciation n'a pas pu être chargée : elle restera indisponible.")
        return None


def create_app(moteurs: Moteurs | None = None, charger: bool = True,
               prononciation=None) -> FastAPI:
    """`moteurs` et `prononciation` : des modèles déjà prêts (les tests passent des
    faux). Sans eux et avec `charger`, les vrais sont chargés au démarrage ; sans eux
    et sans `charger`, le serveur ne fait que répondre au voyant."""

    @asynccontextmanager
    async def demarrage(app: FastAPI):
        if app.state.moteurs is None and charger:
            app.state.moteurs = charger_moteurs()
        if app.state.prononciation is None and charger:
            app.state.prononciation = charger_prononciation()
        yield

    app = FastAPI(title="Assimil, serveur de la maison", version=VERSION, lifespan=demarrage)
    app.state.moteurs = moteurs
    app.state.prononciation = prononciation
    # Une carte graphique, un utilisateur : les tours passent l'un après l'autre.
    verrou = threading.Lock()

    def prets(request: Request) -> Moteurs:
        m = request.app.state.moteurs
        if m is None:
            raise HTTPException(503, "La conversation n'est pas chargée sur ce serveur.")
        return m

    def chrono(fonction, *args):
        debut = time.perf_counter()
        resultat = fonction(*args)
        return resultat, round(time.perf_counter() - debut, 2)

    def penser(fonction, messages):
        try:
            return chrono(fonction, messages)
        except OllamaIndisponible as erreur:
            raise HTTPException(503, "L'IA ne répond pas : Ollama est-il lancé sur le PC ?") from erreur

    def repliquer(m: Moteurs, messages: list[dict]) -> tuple[str, str, float, float]:
        reponse, ia = penser(m.repondre, messages)
        audio, voix = chrono(m.dire, reponse)
        return reponse, base64.b64encode(audio).decode(), ia, voix

    @app.get("/health")
    def health(request: Request) -> Health:
        """Ce que le voyant de l'app interroge : le serveur répond, sur quelle carte,
        et quels modules sont prêts."""
        etat = request.app.state
        modules = [nom for nom, pret in (("conversation", etat.moteurs), ("pronunciation", etat.prononciation))
                   if pret is not None]
        return Health(status="ok", version=VERSION, api=API_VERSION, gpu=gpu_name(), modules=modules)

    @app.post("/conversation/start")
    def start(request: Request, body: StartRequest | None = None) -> Reply:
        """La première réplique : l'IA salue et propose un sujet."""
        m = prets(request)
        if body and body.profile:
            journal.info("Profil reçu : %s", body.profile.model_dump_json())
        with verrou:
            reponse, audio, ia, voix = repliquer(m, messages_ouverture(body.topic if body else None,
                                                                       body.profile if body else None))
        return Reply(reply=reponse, audio=audio, timings=Timings(think=ia, speak=voix))

    @app.post("/conversation/turn")
    def turn(request: Request,
             history: str = Form("[]", description="les répliques précédentes, en JSON"),
             audio: UploadFile | None = File(None),
             text: str | None = Form(None),
             profile: str | None = Form(None, description="le profil de l'apprenant, en JSON")) -> Turn:
        """Un tour : ce que l'apprenant a dit (audio, ou texte), et la réponse."""
        m = prets(request)
        try:
            historique = TypeAdapter(list[Message]).validate_json(history)
        except ValidationError as erreur:
            raise HTTPException(422, f"Historique illisible : {erreur.errors()[0]['msg']}") from erreur
        try:
            profil = Profil.model_validate_json(profile) if profile else None
        except ValidationError as erreur:
            raise HTTPException(422, f"Profil illisible : {erreur.errors()[0]['msg']}") from erreur
        if audio is None and not (text and text.strip()):
            raise HTTPException(422, "Il faut un audio ou un texte.")
        with verrou:
            if audio is not None:
                compris, ecoute = chrono(m.ecouter, audio.file.read(), derniere_replique(historique))
            else:
                compris, ecoute = text.strip(), None
            if not compris:
                raise HTTPException(422, "Je n'ai rien entendu.")
            reponse, son, ia, voix = repliquer(m, messages_tour(historique, compris, profil))
        return Turn(heard=compris, reply=reponse, audio=son,
                    timings=Timings(listen=ecoute, think=ia, speak=voix))

    @app.post("/conversation/review")
    def review(request: Request, body: ReviewRequest) -> Review:
        """Le récapitulatif : les phrases fautives de l'apprenant, corrigées."""
        m = prets(request)
        if not any(msg.role == "user" for msg in body.history):
            return Review(corrections=[])
        with verrou:
            corrections, _ = penser(m.corriger, messages_correction(body.history))
        return Review(corrections=corrections.corrections)

    @app.post("/pronunciation")
    def pronunciation(request: Request,
                      audio: UploadFile = File(..., description="la phrase dite (m4a, wav…)"),
                      text: str = Form(..., description="la phrase attendue")) -> Pronunciation:
        """Juge chaque son d'une phrase lue : les fautes d'un francophone (θ, jota, r, v)
        et tout son trop loin de ce que disent les natifs."""
        analyseur = request.app.state.prononciation
        if analyseur is None:
            raise HTTPException(503, "La prononciation n'est pas chargée sur ce serveur.")
        if not text.strip():
            raise HTTPException(422, "Il faut la phrase attendue.")
        from .moteurs import decoder_16k

        try:
            son = decoder_16k(audio.file.read())
        except subprocess.CalledProcessError as erreur:
            raise HTTPException(422, "Audio illisible.") from erreur
        if len(son) < DUREE_MIN * 16000:
            raise HTTPException(422, "L'enregistrement est trop court.")
        with verrou:
            try:
                resultat, duree = chrono(analyseur.analyser, son, text)
            except ValueError as erreur:  # la phrase ne se transcrit pas en sons
                raise HTTPException(422, f"Phrase illisible : {erreur}") from erreur
        return Pronunciation(words=par_mots(resultat), heard=" ".join(resultat["entendu"]),
                             seconds=duree)

    return app


app = create_app()
