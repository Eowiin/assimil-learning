"""Kaldi-compatible log-mel filterbank in numpy (lhotse `Fbank` defaults, as used by
icefall/ZIPA): 25 ms povey window, 10 ms shift, pre-emphasis 0.97, DC removal, 512-point
power spectrum, 80 mel bins in 20..7600 Hz, reflected edges (snip_edges=False).

Kept dependency-free so it ports to Swift/Accelerate along with the model.
"""

import numpy as np

FRAME_LENGTH = 400  # samples at 16 kHz
FRAME_SHIFT = 160
N_FFT = 512
EPS = float(np.finfo(np.float32).eps)


def _mel(f: np.ndarray | float) -> np.ndarray:
    return 1127.0 * np.log(1.0 + np.asarray(f) / 700.0)


def mel_banks(num_bins: int = 80, sample_rate: int = 16_000, low: float = 20.0,
              high: float = -400.0) -> np.ndarray:
    """(N_FFT // 2 + 1, num_bins) triangular filters on the Kaldi mel scale."""
    high = sample_rate / 2 + high if high <= 0 else high
    mel_low, mel_high = _mel(low), _mel(high)
    delta = (mel_high - mel_low) / (num_bins + 1)
    left = mel_low + np.arange(num_bins)[:, None] * delta
    center, right = left + delta, left + 2 * delta
    mel = _mel(sample_rate / N_FFT * np.arange(N_FFT // 2))[None, :]
    up = (mel - left) / (center - left)
    down = (right - mel) / (right - center)
    banks = np.maximum(0.0, np.minimum(up, down))  # (num_bins, N_FFT/2)
    return np.pad(banks, ((0, 0), (0, 1))).T.astype(np.float32)  # Nyquist bin unused


_BANKS = mel_banks()
_WINDOW = (np.hanning(FRAME_LENGTH) ** 0.85).astype(np.float64)  # povey


def fbank(audio: np.ndarray) -> np.ndarray:
    """`audio`: mono float at 16 kHz in [-1, 1] -> (frames, 80) float32."""
    x = np.asarray(audio, dtype=np.float64)
    num_frames = (len(x) + FRAME_SHIFT // 2) // FRAME_SHIFT
    pad_left = (FRAME_LENGTH - FRAME_SHIFT) // 2
    pad_right = (num_frames - 1) * FRAME_SHIFT + FRAME_LENGTH - len(x) - pad_left
    right = x[::-1][:pad_right] if pad_right > 0 else x[:0]
    x = np.concatenate([x[:pad_left][::-1], x, right])
    idx = np.arange(num_frames)[:, None] * FRAME_SHIFT + np.arange(FRAME_LENGTH)[None, :]
    frames = x[idx]
    frames = frames - frames.mean(axis=1, keepdims=True)
    frames = frames - 0.97 * np.concatenate([frames[:, :1], frames[:, :-1]], axis=1)
    frames = frames * _WINDOW
    power = np.abs(np.fft.rfft(frames, n=N_FFT, axis=1)) ** 2
    return np.log(np.maximum(power @ _BANKS, EPS)).astype(np.float32)
