"""L'IA qui écrit et qui juge : Mistral, par son API.

Le reste du serveur ne voit que le protocole `LLM` : une réponse libre (`chat`) ou
une réponse qui suit un schéma (`structured`). Mistral est la seule IA depuis le
2026-11-18 : Qwen3 8B, servi par Ollama sur le PC, corrigeait des phrases justes,
jugeait l'objectif au hasard et marquait mal le placement (28 défis sur 35, contre 32
pour Mistral, deux fois plus vite). Le protocole reste, pour une autre IA un jour.
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
    # Ce que le journal affiche au démarrage : « mistral mistral-small-latest ».
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


class MistralLLM:
    """Un modèle de Mistral, par son API (`/v1/chat/completions`). La clé vient de
    `MISTRAL_API_KEY` ; elle ne s'affiche nulle part."""

    def __init__(self, cle: str, modele: str = "mistral-small-latest",
                 url: str = "https://api.mistral.ai", client: httpx.Client | None = None):
        if not cle:
            raise ValueError("L'IA (Mistral) demande la clé dans MISTRAL_API_KEY.")
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


def choisir_llm(env=os.environ) -> LLM:
    """Mistral, réglé par les variables d'environnement : la clé (`MISTRAL_API_KEY`) et
    le modèle (`ASSIMIL_MISTRAL_MODELE`)."""
    return MistralLLM(cle=env.get("MISTRAL_API_KEY", ""),
                      modele=env.get("ASSIMIL_MISTRAL_MODELE", "mistral-small-latest"))
