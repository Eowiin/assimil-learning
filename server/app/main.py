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

from .conversation import (Correction, CorrectionEcrite, Corrections, CorrectionsEcrit,
                           CorrectionsEcritObjectif, CorrectionsObjectif, Message, Moteurs, Niveau,
                           Objectif, Profil, UsageObjectif, connus_du_tour, derniere_replique,
                           lemmes_produits, messages_correction, messages_ecrit, messages_ouverture,
                           messages_tour, mesurer, vraies_corrections)
from .langue import Langue
from .llm import LLMIndisponible
from .placement import JugementDefi, PlacementRequest, evaluer
from .prononciation.jugement import par_mots
from .seance import InputRequest, InputText, generer

VERSION = "0.2.0"
# Monte quand une route change de forme : l'app saura qu'elle parle à un serveur
# trop ancien ou trop récent pour elle. Ajouter une route ne la fait pas monter :
# `modules` dit ce qui est prêt. Ajouter un champ optionnel non plus : l'app
# d'aujourd'hui exige l'égalité (`HomeServer.supportedAPI`), monter couperait le serveur
# de l'app sans rien lui apporter.
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
    """Une réplique de l'IA. `audio` est un .m4a (AAC) en base64. `coverage` : la part
    de mots connus de la réplique, et `attempts` : combien de versions l'IA en a
    écrites (1 à 3), quand le profil donne `allowed_lemmas` et que la langue est
    chargée ; null sinon."""
    reply: str
    audio: str
    timings: Timings
    coverage: float | None = None
    attempts: int | None = None


class Turn(Reply):
    heard: str


class StartRequest(BaseModel):
    topic: str | None = None
    profile: Profil | None = None


class ReviewRequest(BaseModel):
    history: list[Message]
    objective: Objectif | None = None
    level: Niveau | None = None


class Review(BaseModel):
    """`objective_uses` : null sans objectif demandé. `lemmas_produced` : les lemmes
    des phrases de l'apprenant, par spaCy ; null si la langue n'est pas chargée."""
    corrections: list[Correction]
    objective_uses: list[UsageObjectif] | None = None
    lemmas_produced: list[str] | None = None


class WritingRequest(BaseModel):
    text: str
    level: Niveau | None = None
    objective: Objectif | None = None


class WritingReview(BaseModel):
    corrections: list[CorrectionEcrite]
    corrected_text: str
    objective_uses: list[UsageObjectif] | None = None
    lemmas_produced: list[str] | None = None


# Les phrases dites en une demande : le texte du bloc 2 en compte une vingtaine.
PHRASES_TTS_AU_PLUS = 40


class TTSRequest(BaseModel):
    sentences: list[str] = Field(min_length=1, max_length=PHRASES_TTS_AU_PLUS)


class SentenceAudio(BaseModel):
    """Une phrase et sa voix, un .m4a (AAC) en base64."""
    text: str
    audio: str


class Speech(BaseModel):
    audios: list[SentenceAudio]
    seconds: float


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
    journal.info("Chargement de Whisper %s et de la voix…", reglages.whisper)
    moteurs = Reels.charger(reglages)
    journal.info("IA : %s. Juge : %s. Voix : %s.", moteurs.llm.nom, moteurs.juge.nom, moteurs.tts.nom)
    debut = time.perf_counter()
    try:
        moteurs.prechauffer()
        journal.info("Tour à vide fait en %.1f s.", time.perf_counter() - debut)
    except LLMIndisponible as erreur:
        journal.warning("L'IA ne répond pas (%s) : la conversation attendra.", erreur)
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


def charger_langue() -> Langue | None:
    """spaCy, pour mesurer les mots connus d'un texte. S'il manque, le reste tourne."""
    from .langue.analyse import MODELE, Spacy

    journal.info("Chargement de la langue (%s)…", MODELE)
    try:
        langue = Spacy()
        langue.lemmatiser("Hola, ¿qué tal?")
        return langue
    except Exception:
        journal.exception("La langue n'a pas pu être chargée : elle restera indisponible.")
        return None


def create_app(moteurs: Moteurs | None = None, charger: bool = True,
               prononciation=None, langue: Langue | None = None) -> FastAPI:
    """`moteurs`, `prononciation` et `langue` : des modèles déjà prêts (les tests passent des
    faux). Sans eux et avec `charger`, les vrais sont chargés au démarrage ; sans eux
    et sans `charger`, le serveur ne fait que répondre au voyant."""

    @asynccontextmanager
    async def demarrage(app: FastAPI):
        if app.state.moteurs is None and charger:
            app.state.moteurs = charger_moteurs()
        if app.state.prononciation is None and charger:
            app.state.prononciation = charger_prononciation()
        if app.state.langue is None and charger:
            app.state.langue = charger_langue()
        yield

    app = FastAPI(title="Assimil, serveur de la maison", version=VERSION, lifespan=demarrage)
    app.state.moteurs = moteurs
    app.state.prononciation = prononciation
    app.state.langue = langue
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

    def penser(fonction, *args):
        try:
            return chrono(fonction, *args)
        except LLMIndisponible as erreur:
            raise HTTPException(503, f"L'IA ne répond pas : {erreur}") from erreur

    def repliquer(request: Request, messages: list[dict], profil: Profil | None,
                  phrase: str | None = None, ecoute: float | None = None) -> Reply:
        """La réplique de l'IA, mesurée si l'app donne les mots connus, puis dite."""
        m = request.app.state.moteurs
        langue: Langue | None = request.app.state.langue
        debut = time.perf_counter()
        reponse, _ = penser(m.repondre, messages)
        couverture = essais = None
        if profil and profil.allowed_lemmas and langue is not None:
            mesure = mesurer(reponse, m.repondre, langue, connus_du_tour(profil, phrase, langue),
                             profil.level)
            reponse, couverture, essais = mesure.texte, mesure.couverture, mesure.essais
            if essais > 1:
                journal.info("Réplique réécrite (%d versions), couverture %.0f %%.",
                             essais, couverture * 100)
        ia = round(time.perf_counter() - debut, 2)
        audio, voix = chrono(m.dire, reponse)
        return Reply(reply=reponse, audio=base64.b64encode(audio).decode(),
                     timings=Timings(listen=ecoute, think=ia, speak=voix),
                     coverage=couverture, attempts=essais)

    def lemmes(request: Request, phrases: list[str]) -> list[str] | None:
        langue: Langue | None = request.app.state.langue
        return lemmes_produits(phrases, langue) if langue is not None else None

    @app.get("/health")
    def health(request: Request) -> Health:
        """Ce que le voyant de l'app interroge : le serveur répond, sur quelle carte,
        et quels modules sont prêts."""
        etat = request.app.state
        moteurs, langue = etat.moteurs is not None, etat.langue is not None
        modules = [nom for nom, pret in (("conversation", moteurs),
                                         ("placement", moteurs),
                                         ("session_input", moteurs and langue),
                                         ("tts", moteurs),
                                         ("pronunciation", etat.prononciation is not None),
                                         ("language", langue))
                   if pret]
        return Health(status="ok", version=VERSION, api=API_VERSION, gpu=gpu_name(), modules=modules)

    @app.post("/conversation/start")
    def start(request: Request, body: StartRequest | None = None) -> Reply:
        """La première réplique : l'IA salue et propose un sujet."""
        prets(request)
        profil = body.profile if body else None
        if profil:
            journal.info("Profil reçu : %s", _resume(profil))
        with verrou:
            return repliquer(request, messages_ouverture(body.topic if body else None, profil), profil)

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
            replique = repliquer(request, messages_tour(historique, compris, profil), profil,
                                 compris, ecoute)
        return Turn(heard=compris, **replique.model_dump())

    @app.post("/conversation/review")
    def review(request: Request, body: ReviewRequest) -> Review:
        """Le récapitulatif : les phrases fautives de l'apprenant, corrigées."""
        m = prets(request)
        phrases = [msg.content for msg in body.history if msg.role == "user"]
        if not phrases:
            return Review(corrections=[], objective_uses=[] if body.objective else None,
                          lemmas_produced=[] if request.app.state.langue is not None else None)
        modele = CorrectionsObjectif if body.objective else Corrections
        with verrou:
            recap, _ = penser(m.structurer,
                              messages_correction(body.history, body.objective, body.level), modele)
            produits = lemmes(request, phrases)
        return Review(corrections=vraies_corrections(recap.corrections),
                      objective_uses=recap.objective_uses if body.objective else None,
                      lemmas_produced=produits)

    @app.post("/writing/review")
    def writing_review(request: Request, body: WritingRequest) -> WritingReview:
        """L'écrit du bloc 4, corrigé : les phrases fautives, le texte entier corrigé, et
        l'objectif du jour jugé."""
        m = prets(request)
        texte = body.text.strip()
        if not texte:
            raise HTTPException(422, "Il faut un texte.")
        modele = CorrectionsEcritObjectif if body.objective else CorrectionsEcrit
        with verrou:
            recap, _ = penser(m.structurer, messages_ecrit(texte, body.objective, body.level), modele)
            produits = lemmes(request, [texte])
        return WritingReview(corrections=vraies_corrections(recap.corrections, ecrit=True),
                             corrected_text=recap.corrected_text,
                             objective_uses=recap.objective_uses if body.objective else None,
                             lemmas_produced=produits)

    @app.post("/placement/evaluate")
    def placement(request: Request, body: PlacementRequest) -> list[JugementDefi]:
        """Les défis du placement, un verdict chacun : `shown`, `correct_not_shown` ou
        `wrong`. Les réponses vides ou identiques au paquet sont triées sans l'IA."""
        m = prets(request)
        with verrou:
            verdicts, duree = penser(evaluer, body.items, m.structurer, body.level)
        journal.info("Placement : %d défis jugés en %.1f s.", len(verdicts), duree)
        return verdicts

    @app.post("/session/generate-input")
    def generate_input(request: Request, body: InputRequest) -> InputText:
        """Le texte du bloc 2, écrit pour l'apprenant et mesuré : 95 % de mots connus
        visés, nouvelle formulation sous 92 %."""
        m = prets(request)
        langue: Langue | None = request.app.state.langue
        if langue is None:
            raise HTTPException(503, "La langue (spaCy) n'est pas chargée sur ce serveur.")
        with verrou:
            texte, duree = penser(generer, body, m.rediger, langue)
        journal.info("Texte du bloc 2 : %d versions, couverture %.0f %%, en %.1f s.",
                     texte.attempts, texte.coverage * 100, duree)
        return texte

    @app.post("/tts")
    def tts(request: Request, body: TTSRequest) -> Speech:
        """Chaque phrase à voix haute, un .m4a par phrase, dans l'ordre."""
        m = prets(request)
        phrases = [p.strip() for p in body.sentences]
        if not all(phrases):
            raise HTTPException(422, "Une phrase est vide.")
        debut = time.perf_counter()
        with verrou:
            audios = [SentenceAudio(text=p, audio=base64.b64encode(m.dire(p)).decode())
                      for p in phrases]
        return Speech(audios=audios, seconds=round(time.perf_counter() - debut, 2))

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


def _resume(profil: Profil) -> str:
    """Le profil pour le journal, sans la liste des lemmes connus (des centaines)."""
    resume = profil.model_dump(exclude={"allowed_lemmas", "objective"}, exclude_none=True)
    if profil.objective:
        resume["objective"] = profil.objective.id
    if profil.allowed_lemmas:
        resume["allowed_lemmas"] = len(profil.allowed_lemmas)
    return str(resume)


app = create_app()
