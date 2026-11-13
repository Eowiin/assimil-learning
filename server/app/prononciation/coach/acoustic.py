"""Acoustic models: audio -> CTC log-posteriors + vocabulary.

Merged from the coach project's acoustic/ package (base, wav2vec2, zipa, __init__).
Everything downstream (alignment, GOP, rhotics) consumes `Posteriors` only.
"""

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .fbank import fbank

SAMPLE_RATE = 16_000

# name -> (backend, Hugging Face id). GOP thresholds exist for the wav2vec2 ones
# (thresholds/gop_<name>.json); zipa-s only serves the uvular and [v] evidence.
MODELS = {
    "xlsr53": ("wav2vec2", "facebook/wav2vec2-xlsr-53-espeak-cv-ft"),
    "lv60": ("wav2vec2", "facebook/wav2vec2-lv-60-espeak-cv-ft"),
    "cnam": ("wav2vec2", "Cnam-LMSSC/wav2vec2-spanish-phonemizer"),
    "zipa-s": ("zipa", "anyspeech/zipa-small-crctc-ns-700k"),
}


@dataclass
class Posteriors:
    log_probs: np.ndarray  # (frames, vocab) log-softmax
    vocab: list[str]
    blank: int
    frame_seconds: float


def load_audio(path: str | Path) -> np.ndarray:
    """Any format ffmpeg reads -> mono float32 at 16 kHz."""
    proc = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(path), "-ac", "1", "-ar", str(SAMPLE_RATE),
         "-f", "f32le", "-"],
        capture_output=True, check=False,
    )
    if proc.returncode != 0:
        raise ValueError(f"cannot decode {path}: {proc.stderr.decode(errors='replace').strip()}")
    return np.frombuffer(proc.stdout, dtype=np.float32).copy()


class Wav2Vec2Phoneme:
    """wav2vec2 CTC phone recognizers (espeak-IPA multilingual, or Spanish-only)."""

    def __init__(self, model_id: str, name: str, device: str | None = None):
        import torch
        from huggingface_hub import snapshot_download
        from transformers import AutoFeatureExtractor, Wav2Vec2ForCTC

        self.name = name
        self.device = device or ("cuda" if torch.cuda.is_available()
                                 else "mps" if torch.backends.mps.is_available() else "cpu")
        self.extractor = AutoFeatureExtractor.from_pretrained(model_id)
        # Read the vocabulary directly: no tokenizer (and no espeak) needed.
        local = Path(snapshot_download(model_id, allow_patterns=["*.json"]))
        vocab = json.loads((local / "vocab.json").read_text(encoding="utf-8"))
        added = local / "added_tokens.json"
        if added.is_file():
            vocab |= json.loads(added.read_text(encoding="utf-8"))
        self.vocab = [""] * (max(vocab.values()) + 1)
        for token, idx in vocab.items():
            self.vocab[idx] = token
        self.model = Wav2Vec2ForCTC.from_pretrained(model_id).to(self.device).eval()
        self.blank = self.model.config.pad_token_id

    def posteriors(self, audio: np.ndarray) -> Posteriors:
        import torch

        inputs = self.extractor(audio, sampling_rate=SAMPLE_RATE, return_tensors="pt")
        with torch.inference_mode():
            logits = self.model(inputs.input_values.to(self.device)).logits[0]
        log_probs = torch.log_softmax(logits.float(), dim=-1).cpu().numpy()
        log_probs = log_probs[:, : len(self.vocab)]
        frame_seconds = len(audio) / SAMPLE_RATE / log_probs.shape[0]
        return Posteriors(log_probs, self.vocab, self.blank, frame_seconds)


class Zipa:
    """ZIPA (Zipformer CR-CTC, multilingual IPA) via ONNX Runtime, on CPU.

    Licence CC-BY-NC-SA: fine for this trial, not for a published app."""

    def __init__(self, model_id: str, name: str, filename: str = "model.onnx"):
        import onnxruntime as ort
        from huggingface_hub import snapshot_download

        self.name = name
        local = Path(snapshot_download(model_id, allow_patterns=[filename, "tokens.txt"]))
        self.vocab = []
        for line in (local / "tokens.txt").read_text(encoding="utf-8").splitlines():
            token, idx = line.rsplit(" ", 1)
            assert int(idx) == len(self.vocab)
            self.vocab.append(token)
        self.blank = self.vocab.index("<blk>")
        options = ort.SessionOptions()
        options.log_severity_level = 3
        self.session = ort.InferenceSession(str(local / filename), options,
                                            providers=["CPUExecutionProvider"])

    def posteriors(self, audio: np.ndarray) -> Posteriors:
        feats = fbank(audio)[None]
        log_probs, _ = self.session.run(
            None, {"x": feats, "x_lens": np.array([feats.shape[1]], dtype=np.int64)})
        log_probs = log_probs[0].astype(np.float32)
        frame_seconds = len(audio) / SAMPLE_RATE / log_probs.shape[0]
        return Posteriors(log_probs, self.vocab, self.blank, frame_seconds)


def load_model(name: str, device: str | None = None):
    if name not in MODELS:
        raise ValueError(f"unknown model {name!r}, choose from {sorted(MODELS)}")
    backend, model_id = MODELS[name]
    hub = os.environ.get("HF_HUB_CACHE") or Path(
        os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface")) / "hub"
    if (Path(hub) / f"models--{model_id.replace('/', '--')}").is_dir():
        os.environ.setdefault("HF_HUB_OFFLINE", "1")  # already downloaded: no Hub requests
    if backend == "zipa":
        return Zipa(model_id, name)
    return Wav2Vec2Phoneme(model_id, name, device)
