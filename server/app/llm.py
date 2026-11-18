"""L'IA qui écrit : Qwen3 par Ollama sur le PC, ou Mistral par son API.

Le reste du serveur ne voit que le protocole `LLM` : une réponse libre (`chat`) ou
une réponse qui suit un schéma (`structured`). Le choix se fait par `ASSIMIL_LLM`
(`ollama` par défaut, ou `mistral`), voir `choisir_llm`.
"""

from __future__ import annotations

import os
from typing import Protocol, TypeVar

import httpx
from pydantic import BaseModel, ValidationError

M = TypeVar("M", bound=BaseModel)


class LLMIndisponible(RuntimeError):
    """L'IA ne répond pas. Le message dit quoi vérifier, il est montré dans l'app."""


class LLM(Protocol):
    # Ce que le journal affiche au démarrage : « ollama qwen3:8b », « mistral … ».
    nom: str

    def chat(self, messages: list[dict], temperature: float = 0.7) -> str:
        """La réplique suivante, consigne comprise dans `messages`."""
        ...

    def structured(self, messages: list[dict], modele: type[M], temperature: float = 0) -> M:
        """Une réponse qui suit le schéma JSON de `modele`, déjà validée."""
        ...

    def prechauffer(self) -> None:
        """Ce qu'il faut faire au démarrage pour que le premier tour soit rapide."""
        ...


def _valider(texte: str, modele: type[M], nom: str) -> M:
    try:
        return modele.model_validate_json(texte)
    except ValidationError as erreur:
        raise LLMIndisponible(f"{nom} a rendu une réponse hors du format demandé.") from erreur


class OllamaLLM:
    """Un modèle d'Ollama, sur le PC. Sa sortie structurée suit le schéma qu'on lui
    donne : pas besoin de la découper à la main."""

    def __init__(self, modele: str = "qwen3:8b", url: str = "http://localhost:11434",
                 garder: str = "30m", client: httpx.Client | None = None):
        self.modele = modele
        # Combien de temps Ollama garde l'IA en mémoire après le dernier tour.
        self.garder = garder
        self.client = client or httpx.Client(base_url=url, timeout=120)
        self.nom = f"ollama {modele}"

    def _appel(self, messages: list[dict], temperature: float, **extra) -> str:
        corps = {"model": self.modele, "messages": messages, "stream": False,
                 "keep_alive": self.garder, "options": {"temperature": temperature}, **extra}
        # Qwen3 réfléchit avant de répondre : utile pour un problème, trop lent pour
        # une conversation.
        if self.modele.startswith("qwen3"):
            corps["think"] = False
        try:
            reponse = self.client.post("/api/chat", json=corps)
            reponse.raise_for_status()
        except httpx.HTTPError as erreur:
            raise LLMIndisponible("Ollama est-il lancé sur le PC ?") from erreur
        # Sans réflexion, Ollama ajoute « /no_think » au dernier message, et Qwen3 le
        # recopie parfois dans ce qu'il cite (« Gracias para preguntar /no_think »,
        # essai du 2026-11-18).
        return reponse.json()["message"]["content"].replace(" /no_think", "").replace(
            "/no_think", "").strip()

    def chat(self, messages: list[dict], temperature: float = 0.7) -> str:
        return self._appel(messages, temperature)

    def structured(self, messages: list[dict], modele: type[M], temperature: float = 0) -> M:
        texte = self._appel(messages, temperature, format=modele.model_json_schema())
        return _valider(texte, modele, "Ollama")

    def prechauffer(self) -> None:
        # Charge le modèle sur la carte graphique.
        self.chat([{"role": "user", "content": "Hola"}])


class MistralLLM:
    """Un modèle de Mistral, par son API (`/v1/chat/completions`). La clé vient de
    `MISTRAL_API_KEY` ; elle ne s'affiche nulle part."""

    def __init__(self, cle: str, modele: str = "mistral-small-latest",
                 url: str = "https://api.mistral.ai", client: httpx.Client | None = None):
        if not cle:
            raise ValueError("ASSIMIL_LLM=mistral demande la clé dans MISTRAL_API_KEY.")
        self.modele = modele
        self.client = client or httpx.Client(base_url=url, timeout=60)
        self.client.headers["Authorization"] = f"Bearer {cle}"
        self.nom = f"mistral {modele}"

    def _appel(self, messages: list[dict], temperature: float, **extra) -> str:
        corps = {"model": self.modele, "messages": messages, "temperature": temperature, **extra}
        try:
            reponse = self.client.post("/v1/chat/completions", json=corps)
            reponse.raise_for_status()
        except httpx.HTTPStatusError as erreur:
            if erreur.response.status_code in (401, 403):
                raise LLMIndisponible("Mistral refuse la clé : vérifie MISTRAL_API_KEY.") from erreur
            raise LLMIndisponible(f"Mistral répond {erreur.response.status_code}.") from erreur
        except httpx.HTTPError as erreur:
            raise LLMIndisponible("Mistral ne répond pas : le PC a-t-il accès à internet ?") from erreur
        return reponse.json()["choices"][0]["message"]["content"].strip()

    def chat(self, messages: list[dict], temperature: float = 0.7) -> str:
        return self._appel(messages, temperature)

    def structured(self, messages: list[dict], modele: type[M], temperature: float = 0) -> M:
        format_impose = {"type": "json_schema",
                         "json_schema": {"name": modele.__name__, "schema": modele.model_json_schema(),
                                         "strict": True}}
        texte = self._appel(messages, temperature, response_format=format_impose)
        return _valider(texte, modele, "Mistral")

    def prechauffer(self) -> None:
        # Rien à charger : le modèle tourne chez Mistral.
        pass


LLMS = ("ollama", "mistral")


def choisir_llm(env=os.environ) -> LLM:
    """L'IA choisie par `ASSIMIL_LLM`, réglée par les variables d'environnement."""
    choix = env.get("ASSIMIL_LLM", "ollama").strip().lower()
    if choix == "ollama":
        return OllamaLLM(modele=env.get("ASSIMIL_IA", "qwen3:8b"),
                         url=env.get("OLLAMA_HOST_URL", "http://localhost:11434"),
                         garder=env.get("ASSIMIL_GARDER_IA", "30m"))
    if choix == "mistral":
        return MistralLLM(cle=env.get("MISTRAL_API_KEY", ""),
                          modele=env.get("ASSIMIL_MISTRAL_MODELE", "mistral-small-latest"))
    raise ValueError(f"ASSIMIL_LLM={choix} : choisir parmi {', '.join(LLMS)}.")
