"""Les protocoles LLM et TTS, et `Reels` qui les assemble, sans aucun modèle :
les appels HTTP passent par un transport simulé."""

import base64
import json
import shutil

import httpx
import pytest
from pydantic import BaseModel

from app.conversation import Correction, Corrections
from app.llm import LLMIndisponible, MistralLLM, choisir_llm
from app.moteurs import Reels, Reglages
from app.voix import (
    Audio,
    TTSAvecSecours,
    VoixIndisponible,
    VoxtralTTS,
    choisir_tts,
    en_m4a,
    ralentir,
    wav_16_bits,
)


def transport(reponse, recus: list):
    """Un faux serveur HTTP : note chaque requête, rend `reponse(requete)`."""
    def gerer(requete: httpx.Request):
        recus.append(requete)
        return reponse(requete)
    return httpx.MockTransport(gerer)


class Verdict(BaseModel):
    ok: bool


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


def test_reponse_hors_format():
    llm, _ = mistral(contenu='{"ok": "peut-être"}')
    with pytest.raises(LLMIndisponible, match="format"):
        llm.structured([], Verdict)


def test_mistral_injoignable():
    def refuser(requete):
        raise httpx.ConnectError("pas de réseau")

    llm = MistralLLM(cle="x", client=httpx.Client(base_url="https://mistral",
                                                  transport=httpx.MockTransport(refuser)))
    with pytest.raises(LLMIndisponible, match="internet"):
        llm.chat([])


# --- Le choix par l'environnement --------------------------------------------------

def test_mistral_par_defaut():
    llm = choisir_llm({"MISTRAL_API_KEY": "x"})
    assert isinstance(llm, MistralLLM) and llm.modele == "mistral-small-latest"


def test_le_modele_se_regle():
    llm = choisir_llm({"MISTRAL_API_KEY": "x", "ASSIMIL_MISTRAL_MODELE": "mistral-medium-latest"})
    assert llm.modele == "mistral-medium-latest"


def test_sans_cle_le_serveur_le_dit():
    with pytest.raises(ValueError, match="MISTRAL_API_KEY"):
        choisir_llm({})


class FausseVoix:
    """Une voix qui rend son nom, ou échoue."""

    def __init__(self, nom="faux", panne=False):
        self.nom = nom
        self.panne = panne
        self.phrases = []

    def dire(self, texte):
        self.phrases.append(texte)
        if self.panne:
            raise VoixIndisponible("en panne")
        return Audio(f"{self.nom}:{texte}".encode(), "wav")


def fausse_pocket(appareil, env):
    return FausseVoix("pocket")


def test_voxtral_par_defaut_avec_pocket_en_secours():
    tts = choisir_tts(env={"MISTRAL_API_KEY": "x"}, pocket=fausse_pocket)
    assert isinstance(tts, TTSAvecSecours)
    assert isinstance(tts.principal, VoxtralTTS) and tts.principal.voix == "voice_483"
    assert tts.secours.nom == "pocket"


def test_voxtral_sans_secours():
    tts = choisir_tts(env={"MISTRAL_API_KEY": "x", "ASSIMIL_TTS_SECOURS": "aucun"}, pocket=fausse_pocket)
    assert isinstance(tts, VoxtralTTS)


def test_voxtral_sans_cle():
    with pytest.raises(ValueError, match="MISTRAL_API_KEY"):
        choisir_tts(env={"ASSIMIL_TTS": "voxtral"}, pocket=fausse_pocket)


def test_pocket_seul():
    assert choisir_tts(env={"ASSIMIL_TTS": "pocket"}, pocket=fausse_pocket).nom == "pocket"


@pytest.mark.parametrize("ecartee", ["phonon", "siri"])
def test_voix_inconnue(ecartee):
    with pytest.raises(ValueError, match="voxtral, pocket, xtts"):
        choisir_tts(env={"ASSIMIL_TTS": ecartee})


# --- La voix -----------------------------------------------------------------------

def voxtral(reponse, recus):
    client = httpx.Client(base_url="https://mistral", transport=transport(reponse, recus))
    return VoxtralTTS(cle="cle-secrete", vitesse=1, client=client)


def test_voxtral_demande_du_wav_a_elena():
    recus = []
    tts = voxtral(lambda _: httpx.Response(200, json={"audio_data": base64.b64encode(b"RIFF").decode()}), recus)
    assert tts.dire("¡Hola!") == Audio(b"RIFF", "wav")
    assert recus[0].url.path == "/v1/audio/speech"
    assert recus[0].headers["Authorization"] == "Bearer cle-secrete"
    assert json.loads(recus[0].content) == {"model": "voxtral-mini-tts-3-0", "input": "¡Hola!",
                                            "voice_id": "voice_483", "response_format": "wav"}
    assert "cle-secrete" not in tts.nom


@pytest.mark.parametrize("reponse", [
    lambda _: httpx.Response(403, json={}),
    lambda _: httpx.Response(200, json={"autre": 1}),
])
def test_voxtral_en_echec(reponse):
    with pytest.raises(VoixIndisponible):
        voxtral(reponse, []).dire("Hola")


def test_voxtral_injoignable():
    def refuser(requete):
        raise httpx.ConnectError("pas de réseau")
    with pytest.raises(VoixIndisponible, match="internet"):
        voxtral(refuser, []).dire("Hola")


def test_le_secours_prend_le_relais_puis_rend_la_main():
    maintenant = [0.0]
    principal, secours = FausseVoix("voxtral", panne=True), FausseVoix("pocket")
    tts = TTSAvecSecours(principal, secours, pause=60, horloge=lambda: maintenant[0])
    assert tts.dire("uno").donnees == b"pocket:uno"
    # Pendant la pause, Voxtral n'est même pas essayé.
    maintenant[0] = 30
    assert tts.dire("dos").donnees == b"pocket:dos"
    assert principal.phrases == ["uno"]
    # Après, il l'est de nouveau.
    principal.panne = False
    maintenant[0] = 61
    assert tts.dire("tres").donnees == b"voxtral:tres"


def test_la_vitesse_de_voxtral_se_regle():
    tts = choisir_tts(env={"MISTRAL_API_KEY": "x", "ASSIMIL_TTS_SECOURS": "aucun"}, pocket=fausse_pocket)
    assert tts.vitesse == 0.9
    tts = choisir_tts(env={"MISTRAL_API_KEY": "x", "ASSIMIL_TTS_SECOURS": "aucun",
                           "ASSIMIL_VOXTRAL_VITESSE": "0.8"}, pocket=fausse_pocket)
    assert tts.vitesse == 0.8
    with pytest.raises(ValueError, match="entre 0,5 et 2"):
        VoxtralTTS(cle="x", vitesse=0.2)


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg absent")
def test_ralentir_allonge_l_audio(tmp_path):
    import io
    import subprocess
    import wave
    wav = tmp_path / "bip.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=1", str(wav)], check=True)
    audio = Audio(wav.read_bytes(), "wav")
    assert ralentir(audio, 1) is audio
    with wave.open(io.BytesIO(ralentir(audio, 0.8).donnees)) as lent:
        assert lent.getnframes() / lent.getframerate() == pytest.approx(1.25, abs=0.05)


def test_wav_16_bits():
    import io
    import wave
    donnees = wav_16_bits([0.0, 0.5, -2.0], 24000)
    with wave.open(io.BytesIO(donnees)) as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) == (1, 2, 24000, 3)

@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg absent")
def test_un_m4a_indexe_a_la_fin_se_decode(tmp_path):
    """Un .m4a dont l'index est à la fin (sans `faststart`) : lu d'un tube, ffmpeg
    n'en tirait rien, sans erreur."""
    import subprocess

    from app.moteurs import decoder_16k
    m4a = tmp_path / "prise.m4a"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=8:sample_rate=48000", "-c:a", "aac", str(m4a)],
                   check=True)
    assert len(decoder_16k(m4a.read_bytes())) / 16000 == pytest.approx(8, abs=0.1)


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


def test_une_seule_ia_ecrit_et_juge():
    llm = FauxLLM()
    reels = Reels(Reglages(), FauxWhisper(), llm, FauxTTS())
    reels.rediger([], Corrections)
    # Écrire le texte du bloc 2 n'est pas juger : à 0.7, pas à 0.
    assert llm.appels == [("structured", 0.7)]


def test_le_prechauffage_passe_par_le_llm(monkeypatch):
    llm = FauxLLM()
    reels = Reels(Reglages(), FauxWhisper(), llm, FauxTTS())
    entendus = []
    monkeypatch.setattr(reels, "ecouter", lambda audio, contexte=None: entendus.append(audio) or "hola")
    reels.prechauffer()
    assert entendus == [b"m4a:Hola, \xc2\xbfqu\xc3\xa9 tal?"]
    assert llm.appels == [("prechauffer", None)]


# --- Écouter : l'espagnol, les deux langues, le français (étape 6b) --------------------

class FauxSegment:
    def __init__(self, texte):
        self.text = texte


class FauxWhisper:
    """Rend un texte par façon d'écouter, et note chaque appel."""

    def __init__(self, bilingue="Quiero un… comment on dit… un couteau."):
        self.bilingue = bilingue
        self.appels = []

    def transcribe(self, audio, language=None, multilingual=False, initial_prompt=None, **_):
        self.appels.append({"language": language, "multilingual": multilingual,
                            "initial_prompt": initial_prompt})
        texte = {"es": "Quiero un cuchillo.", "fr": "couteau"}.get(language, self.bilingue)
        info = type("Info", (), {"language": language or "ko"})()
        return [FauxSegment(texte)], info


@pytest.fixture
def sans_ffmpeg(monkeypatch):
    from app import moteurs
    monkeypatch.setattr(moteurs, "decoder_16k", lambda audio: audio)


def reels(whisper):
    return Reels(Reglages(), whisper, llm=None, tts=None)


def test_ecouter_en_espagnol_par_defaut(sans_ffmpeg):
    whisper = FauxWhisper()
    assert reels(whisper).ecouter(b"x") == "Quiero un cuchillo."
    assert whisper.appels == [{"language": "es", "multilingual": False, "initial_prompt": None}]


def test_ecouter_les_deux_langues_avec_l_amorce(sans_ffmpeg):
    from app.moteurs import AMORCE_BILINGUE
    whisper = FauxWhisper()
    assert reels(whisper).ecouter(b"x", langue="bilingue") == "Quiero un… comment on dit… un couteau."
    assert whisper.appels == [{"language": None, "multilingual": True,
                               "initial_prompt": AMORCE_BILINGUE}]


def test_ecouter_une_demande_en_francais(sans_ffmpeg):
    whisper = FauxWhisper()
    assert reels(whisper).ecouter(b"x", langue="fr") == "couteau"
    assert whisper.appels[0]["language"] == "fr"


def test_hors_alphabet_latin_on_reecoute_en_espagnol(sans_ffmpeg):
    whisper = FauxWhisper(bilingue="아따. 시시이 괴로라 소파.")
    assert reels(whisper).ecouter(b"x", langue="bilingue") == "Quiero un cuchillo."
    assert [a["language"] for a in whisper.appels] == [None, "es"]


def test_hors_latin():
    from app.moteurs import hors_latin
    assert not hors_latin("¿Dónde está la gare? Ça coûte cher, señor. 25 €")
    assert hors_latin("А то.")
    assert hors_latin("아따")
