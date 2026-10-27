"""Local speech-to-text for Bee audio: AAC decoding (PyAV) and Whisper on Apple Silicon (mlx-whisper).

Audio never leaves the Mac. The Whisper model is downloaded once from Hugging Face and cached.
Needs the optional extras: `uv sync --extra transcribe`.
"""

from __future__ import annotations

import importlib
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

import numpy as np

SAMPLE_RATE = 16000
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
QUIET_CHUNK_DBFS = -50.0  # chunks quieter than this overall are skipped (Whisper hallucinates on silence)


class MissingExtras(RuntimeError):
    pass


def _require(module: str) -> ModuleType:
    try:
        return importlib.import_module(module)
    except ImportError as e:
        raise MissingExtras(f"{module} is missing; install with `uv sync --extra transcribe`") from e


def dbfs(pcm: np.ndarray) -> float:
    if not len(pcm):
        return -120.0
    rms = float(np.sqrt(np.mean(np.square(pcm, dtype=np.float64))))
    return 20 * np.log10(rms) if rms > 0 else -120.0


def _resampler():
    return _require("av").AudioResampler(format="flt", layout="mono", rate=SAMPLE_RATE)


def _to_pcm(frames, resampler) -> np.ndarray:
    chunks = [out.to_ndarray().reshape(-1) for frame in frames for out in resampler.resample(frame)]
    return np.concatenate(chunks).astype(np.float32) if chunks else np.zeros(0, np.float32)


class AacDecoder:
    """Streaming ADTS/AAC bytes -> float32 mono PCM at 16 kHz."""

    def __init__(self) -> None:
        self._ctx = _require("av").CodecContext.create("aac", "r")
        self._resampler = _resampler()

    def decode(self, adts: bytes) -> np.ndarray:
        frames = [f for packet in self._ctx.parse(adts) for f in self._ctx.decode(packet)]
        return _to_pcm(frames, self._resampler)


def load_audio(path: Path) -> np.ndarray:
    """Any audio file ffmpeg can read (the Bee's .aac included) -> float32 mono PCM at 16 kHz."""
    with _require("av").open(str(path)) as container:
        return _to_pcm(container.decode(audio=0), _resampler())


class Chunker:
    """Cuts a live PCM stream into pieces for Whisper without splitting words.

    A chunk ends when at least `min_s` of audio is followed by `pause_s` of quiet, or, failing
    that, at the quietest moment in the last 10 s once it reaches `max_s` (Whisper's window is 30 s).
    """

    def __init__(self, min_s: float = 6.0, max_s: float = 28.0, pause_s: float = 0.8, quiet_dbfs: float = -45.0):
        self.min_len = int(min_s * SAMPLE_RATE)
        self.max_len = int(max_s * SAMPLE_RATE)
        self.pause_len = int(pause_s * SAMPLE_RATE)
        self.quiet_dbfs = quiet_dbfs
        self._buf = np.zeros(0, np.float32)
        self._consumed = 0  # samples already emitted, for chunk offsets

    def push(self, pcm: np.ndarray) -> list[tuple[float, np.ndarray]]:
        """Returns (offset seconds from stream start, samples) for each completed chunk."""
        self._buf = np.concatenate([self._buf, pcm])
        chunks = []
        while True:
            cut = self._find_cut()
            if cut is None:
                return chunks
            chunks.append(self._emit(cut))

    def flush(self) -> tuple[float, np.ndarray] | None:
        return self._emit(len(self._buf)) if len(self._buf) else None

    def _find_cut(self) -> int | None:
        n = len(self._buf)
        if n >= self.min_len and dbfs(self._buf[-self.pause_len :]) < self.quiet_dbfs:
            return n
        if n >= self.max_len:
            window = SAMPLE_RATE // 10
            start = self.max_len - 10 * SAMPLE_RATE
            levels = [dbfs(self._buf[i : i + window]) for i in range(start, self.max_len - window + 1, window)]
            return start + int(np.argmin(levels)) * window + window // 2
        return None

    def _emit(self, cut: int) -> tuple[float, np.ndarray]:
        chunk, self._buf = self._buf[:cut], self._buf[cut:]
        offset = self._consumed / SAMPLE_RATE
        self._consumed += cut
        return offset, chunk


@dataclass(frozen=True)
class Segment:
    start: float  # seconds from the start of the audio passed in (plus offset)
    end: float
    text: str


class Transcriber:
    def __init__(self, model: str = DEFAULT_MODEL, language: str | None = None):
        self._whisper = _require("mlx_whisper")
        self.model = model
        self.language = language

    def warm_up(self) -> None:
        """Downloads (first run) and loads the model, so the first real chunk isn't slow."""
        self._whisper.transcribe(np.zeros(SAMPLE_RATE, np.float32), path_or_hf_repo=self.model, language="en")

    def transcribe(self, pcm: np.ndarray, offset: float = 0.0) -> list[Segment]:
        if dbfs(pcm) < QUIET_CHUNK_DBFS:
            return []
        result = self._whisper.transcribe(
            pcm.astype(np.float32),
            path_or_hf_repo=self.model,
            language=self.language,
            condition_on_previous_text=False,  # stops one hallucination from feeding the next
            word_timestamps=True,
            hallucination_silence_threshold=2.0,
        )
        return [
            Segment(offset + s["start"], offset + s["end"], s["text"].strip())
            for s in result["segments"]
            if s["text"].strip() and s.get("no_speech_prob", 0) < 0.8
        ]
