"""Les protocoles LLM et TTS, et `Reels` qui les assemble, sans aucun modèle :
les appels HTTP passent par un transport simulé."""

import json
import shutil

import httpx
import pytest
from pydantic import BaseModel

from app.conversation import Correction, Corrections
from app.llm import LLMIndisponible, MistralLLM, OllamaLLM, choisir_llm
from app.moteurs import Reels, Reglages
from app.voix import Audio, choisir_tts, en_m4a


def transport(reponse, recus: list):
    """Un faux serveur HTTP : note chaque requête, rend `reponse(requete)`."""
    def gerer(requete: httpx.Request):
        recus.append(requete)
        return reponse(requete)
    return httpx.MockTransport(gerer)


class Verdict(BaseModel):
    ok: bool


# --- Ollama ------------------------------------------------------------------------

def ollama(contenu="¡Hola!", statut=200, modele="qwen3:8b"):
    recus = []
    client = httpx.Client(base_url="http://ollama", transport=transport(
        lambda _: httpx.Response(statut, json={"message": {"content": contenu}}), recus))
    return OllamaLLM(modele=modele, client=client), recus


def test_ollama_chat_comme_avant():
    llm, recus = ollama(contenu="  ¿Qué tal?  ")
    assert llm.chat([{"role": "user", "content": "Hola"}], temperature=0.7) == "¿Qué tal?"
    corps = json.loads(recus[0].content)
    assert recus[0].url.path == "/api/chat"
    assert corps["think"] is False and corps["stream"] is False
    assert corps["keep_alive"] == "30m"
    assert corps["options"] == {"temperature": 0.7}
    assert "format" not in corps


def test_ollama_ne_coupe_la_reflexion_que_de_qwen3():
    llm, recus = ollama(modele="mistral-nemo")
    llm.chat([])
    assert "think" not in json.loads(recus[0].content)


def test_ollama_ote_le_no_think_que_qwen3_recopie():
    llm, _ = ollama(contenu='{"said": "Gracias para preguntar /no_think"}')
    assert llm.chat([]) == '{"said": "Gracias para preguntar"}'


def test_ollama_structured_impose_le_schema():
    llm, recus = ollama(contenu='{"ok": true}')
    assert llm.structured([], Verdict) == Verdict(ok=True)
    corps = json.loads(recus[0].content)
    assert corps["format"] == Verdict.model_json_schema()
    assert corps["options"] == {"temperature": 0}


def test_ollama_eteint():
    def refuser(requete):
        raise httpx.ConnectError("connexion refusée", request=requete)
    llm = OllamaLLM(client=httpx.Client(base_url="http://ollama", transport=httpx.MockTransport(refuser)))
    with pytest.raises(LLMIndisponible, match="Ollama"):
        llm.chat([])


def test_reponse_hors_format():
    llm, _ = ollama(contenu='{"ok": "peut-être"}')
    with pytest.raises(LLMIndisponible, match="format"):
        llm.structured([], Verdict)


# --- Mistral -----------------------------------------------------------------------

def mistral(contenu="¡Hola!", statut=200):
    recus = []
    client = httpx.Client(base_url="https://mistral", transport=transport(
        lambda _: httpx.Response(statut, json={"choices": [{"message": {"content": contenu}}]}), recus))
    return MistralLLM(cle="cle-secrete", modele="mistral-small-latest", client=client), recus


def test_mistral_chat():
    llm, recus = mistral()
    assert llm.chat([{"role": "user", "content": "Hola"}], temperature=0.7) == "¡Hola!"
    assert recus[0].url.path == "/v1/chat/completions"
    assert recus[0].headers["Authorization"] == "Bearer cle-secrete"
    corps = json.loads(recus[0].content)
    assert corps["model"] == "mistral-small-latest"
    assert corps["temperature"] == 0.7
    assert "response_format" not in corps


def test_mistral_structured_impose_le_schema():
    llm, recus = mistral(contenu='{"corrections": []}')
    assert llm.structured([], Corrections) == Corrections()
    format_impose = json.loads(recus[0].content)["response_format"]
    assert format_impose["type"] == "json_schema"
    assert format_impose["json_schema"]["name"] == "Corrections"
    assert format_impose["json_schema"]["schema"] == Corrections.model_json_schema()


def test_mistral_cle_refusee():
    llm, _ = mistral(statut=401)
    with pytest.raises(LLMIndisponible, match="MISTRAL_API_KEY"):
        llm.chat([])


def test_mistral_sans_cle():
    with pytest.raises(ValueError, match="MISTRAL_API_KEY"):
        MistralLLM(cle="")


def test_le_nom_ne_montre_pas_la_cle():
    llm, _ = mistral()
    assert "cle-secrete" not in llm.nom


# --- Le choix par l'environnement --------------------------------------------------

def test_ollama_par_defaut():
    llm = choisir_llm({})
    assert isinstance(llm, OllamaLLM) and llm.modele == "qwen3:8b"


def test_choisir_mistral():
    llm = choisir_llm({"ASSIMIL_LLM": "mistral", "MISTRAL_API_KEY": "x",
                       "ASSIMIL_MISTRAL_MODELE": "mistral-medium-latest"})
    assert isinstance(llm, MistralLLM) and llm.modele == "mistral-medium-latest"


def test_choix_inconnu():
    with pytest.raises(ValueError, match="ollama, mistral"):
        choisir_llm({"ASSIMIL_LLM": "gpt"})


@pytest.mark.parametrize("prevu", ["pocket", "phonon", "voxtral"])
def test_les_voix_prevues_sont_annoncees_pas_encore_ecrites(prevu):
    with pytest.raises(ValueError, match="pas encore écrit"):
        choisir_tts(env={"ASSIMIL_TTS": prevu})


def test_voix_inconnue():
    with pytest.raises(ValueError, match="xtts"):
        choisir_tts(env={"ASSIMIL_TTS": "siri"})


# --- La voix -----------------------------------------------------------------------

def test_un_m4a_passe_sans_conversion():
    assert en_m4a(Audio(b"deja-en-m4a", "m4a")) == b"deja-en-m4a"


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg absent")
def test_un_wav_devient_m4a(tmp_path):
    import subprocess
    wav = tmp_path / "bip.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=0.5", str(wav)], check=True)
    m4a = en_m4a(Audio(wav.read_bytes(), "wav"))
    assert m4a[4:8] == b"ftyp"  # l'en-tête d'un conteneur MP4


# --- Reels -------------------------------------------------------------------------

class FauxLLM:
    nom = "faux"

    def __init__(self):
        self.appels = []

    def chat(self, messages, temperature=0.7):
        self.appels.append(("chat", temperature))
        return "¿Y tú?"

    def structured(self, messages, modele, temperature=0):
        self.appels.append(("structured", temperature))
        return modele(corrections=[Correction(said="a", corrected="b", explanation="c",
                                              category="grammaire", tag="d")])

    def prechauffer(self):
        self.appels.append(("prechauffer", None))


class FauxTTS:
    nom = "faux"

    def dire(self, texte):
        return Audio(f"m4a:{texte}".encode(), "m4a")


class FauxWhisper:
    pass


def test_reels_assemble_sans_changer_les_reglages_de_la_conversation():
    llm = FauxLLM()
    reels = Reels(Reglages(), FauxWhisper(), llm, FauxTTS())
    assert reels.repondre([]) == "¿Y tú?"
    assert reels.structurer([], Corrections).corrections[0].tag == "d"
    # Une réplique à 0.7, une correction à 0, comme avant les protocoles.
    assert llm.appels == [("chat", 0.7), ("structured", 0)]
    assert reels.dire("Hola") == b"m4a:Hola"


def test_le_prechauffage_passe_par_le_llm(monkeypatch):
    llm = FauxLLM()
    reels = Reels(Reglages(), FauxWhisper(), llm, FauxTTS())
    entendus = []
    monkeypatch.setattr(reels, "ecouter", lambda audio, contexte=None: entendus.append(audio) or "hola")
    reels.prechauffer()
    assert entendus == [b"m4a:Hola, \xc2\xbfqu\xc3\xa9 tal?"]
    assert llm.appels == [("prechauffer", None)]
