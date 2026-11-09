"""Local, network-denied Kokoro RPC worker. Model and voices are always local.

Protocol: one JSON object per line on stdin and stdout.

  -> {"rpcId": 1, "action": "start", "requestId": "r1", "text": "...", "voice": "af_aoede", "speed": 1.0}
  <- {"rpcId": 1, "result": {"done": false, "audioBase64": "<WAV>", "mimeType": "audio/wav",
                             "textStart": 0, "textEnd": 42, "words": [[0, 5, 0.0, 0.31], ...]}}
  -> {"rpcId": 2, "action": "next", "requestId": "r1"}
  <- ... until {"done": true}
  -> {"rpcId": 9, "action": "cancel", "requestId": "r1"}

Text offsets are UTF-16 code units (like NSString), and word times are seconds
from the start of that chunk's audio. A chunk is a sentence or a few short ones.
"""

import base64
from collections import deque
import io
import json
import logging
import os
from pathlib import Path
import re
import sys
import threading
import wave

ROOT = Path(__file__).resolve().parent
PROTOCOL = sys.stdout
sys.stdout = open(os.devnull, "w")  # Library diagnostics must never enter the RPC stream.
logging.disable(logging.CRITICAL)
OUTPUT_LOCK = threading.Lock()
MAX_TEXT = 200000
PROTOCOL_VERSION = 3
MIN_SPEED = 0.5
MAX_SPEED = 2.0
SAMPLE_RATE = 24000
MAX_PHONEMES = 480          # the model's context is 510 tokens
FIRST_CHUNK_CHARS = 140     # short first chunk so speech starts quickly
CHUNK_CHARS = 300
WORD = re.compile(r"\S+")
SENTENCE_END = re.compile(r"[.!?;:…][\"'”’)\]]*$")


def reply(value):
    with OUTPUT_LOCK:
        PROTOCOL.write(json.dumps(value, separators=(",", ":")) + "\n")
        PROTOCOL.flush()


def error(rpc_id, code="SPEECH_FAILED"):
    reply({"rpcId": rpc_id, "error": {"code": code, "message": code}})


def utf16_offsets(text):
    """offsets[i] is the UTF-16 offset of Python index i."""
    offsets = [0] * (len(text) + 1)
    total = 0
    for index, character in enumerate(text):
        total += 2 if ord(character) > 0xFFFF else 1
        offsets[index + 1] = total
    return offsets


def word_groups(words, text):
    """Split word spans into chunks, preferring to end at a sentence boundary."""
    index = 0
    limit = FIRST_CHUNK_CHARS
    while index < len(words):
        start = words[index][0]
        end = index
        best = None
        while end < len(words) and (end == index or words[end][1] - start <= limit):
            if SENTENCE_END.search(text[words[end][0]:words[end][1]]) and words[end][1] - start >= limit * 0.25:
                best = end
            end += 1
        last = best if best is not None and end < len(words) else end - 1
        yield index, last + 1
        index = last + 1
        limit = CHUNK_CHARS


def phoneme_word_spans(phonemes):
    """Character spans of the space-separated words in a phoneme string."""
    return [(match.start(), match.end()) for match in re.finditer(r"[^ ]+", phonemes)]


class Engine:
    def __init__(self, root):
        import numpy as np
        self.np = np
        self.root = root
        self.config = json.loads((root / "engine.json").read_text())
        self.kind = self.config["engine"]
        if self.kind not in ("mlx", "onnx"):
            raise RuntimeError("Unknown local engine")
        self.bank = np.load(root / "models/voices-v1.0.bin", allow_pickle=False)
        self.voices = sorted(v for v in self.bank.files if re.fullmatch(r"(?:af|am|bf|bm)_[a-z0-9]+", v))
        self.model = None
        self.tokenizer = None
        self.styles = {}

    def metadata(self, selected):
        return {"voices": [{"id": v, "name": v.split("_", 1)[1].replace("_", " ").title(), "lang": "en-GB" if v[0] == "b" else "en-US"} for v in self.voices], "selectedVoice": selected, "engine": self.kind}

    def load(self):
        if self.model is not None:
            return
        from kokoro_onnx.tokenizer import Tokenizer
        if self.kind == "onnx":
            self.tokenizer = Tokenizer()
            import onnxruntime as ort
            from kokoro_onnx import Kokoro
            options = ort.SessionOptions()
            options.intra_op_num_threads = 4
            options.inter_op_num_threads = 1
            options.add_session_config_entry("session.intra_op.allow_spinning", "0")
            session = ort.InferenceSession(str(self.root / "models/kokoro-v1.0.onnx"), sess_options=options, providers=["CPUExecutionProvider"])
            self.model = Kokoro.from_session(session, str(self.root / "models/voices-v1.0.bin"))
        else:
            import mlx.core as mx
            from mlx_audio.tts.models.kokoro.kokoro import Model, ModelConfig
            self.mx = mx
            if not mx.metal.is_available():
                raise RuntimeError("Metal GPU is unavailable")
            mx.set_default_device(mx.gpu)
            mx.set_cache_limit(128 * 1024**2)
            model_root = self.root / "models/mlx"
            config = json.loads((model_root / "config.json").read_text())
            model = Model(ModelConfig.from_dict(config))
            self.tokenizer = Tokenizer(vocab=model.vocab)
            weights = mx.load(str(model_root / "model.safetensors"))
            model.load_weights(list(model.sanitize(weights).items()), strict=True)
            model.eval()
            if self.config.get("dtype") == "bfloat16":
                model.set_dtype(mx.bfloat16)
            mx.eval(model.parameters())
            self.model = model
            del weights
            mx.clear_cache()

    def chunks(self, text, voice):
        """Lazily yields (word spans, phonemes) per chunk, phonemizing one chunk at a time."""
        self.load()
        language = "en-gb" if voice[0] == "b" else "en-us"
        words = [(m.start(), m.end()) for m in WORD.finditer(text)]
        pending = deque(word_groups(words, text))
        while pending:
            first, last = pending.popleft()
            spans = words[first:last]
            phonemes = self.tokenizer.phonemize(text[spans[0][0]:spans[-1][1]], language)
            if len(phonemes) > MAX_PHONEMES and last - first > 1:
                middle = (first + last) // 2
                pending.extendleft([(middle, last), (first, middle)])
                continue
            yield spans, phonemes[:MAX_PHONEMES]

    def render(self, phonemes, voice, speed=1.0):
        """Returns (float audio, [(start_s, end_s)] per phoneme word or None)."""
        np = self.np
        timings = None
        if self.kind == "onnx":
            audio, rate = self.model.create(phonemes, voice=voice, is_phonemes=True, speed=speed)
        else:
            mx = self.mx
            known = "".join(p for p in phonemes if p in self.model.vocab)
            if not 0 < len(known) <= 500:
                raise RuntimeError("Invalid phoneme chunk length")
            if voice not in self.styles:
                dtype = mx.bfloat16 if self.config.get("dtype") == "bfloat16" else mx.float32
                self.styles[voice] = mx.array(self.bank[voice], dtype=dtype)
                mx.eval(self.styles[voice])
            ref = self.styles[voice][min(len(known), len(self.bank[voice])) - 1]
            output = self.model(known, ref, speed=speed, return_output=True)
            audio = np.array(output.audio.reshape(-1).astype(mx.float32))
            durations = np.array(output.pred_dur).astype(np.int64)
            del output, ref
            mx.clear_cache()
            rate = SAMPLE_RATE
            # pred_dur has one entry per token plus a boundary token at each end.
            if len(durations) == len(known) + 2 and durations.sum() > 0:
                per_frame = len(audio) / durations.sum()
                edges = np.concatenate([[0], np.cumsum(durations)]) * per_frame
                timings = [(edges[a + 1], edges[b + 1]) for a, b in phoneme_word_spans(known)]
            from kokoro_onnx.trim import trim
            audio, kept = trim(audio)
            if timings is not None:
                offset = int(kept[0])
                timings = [(max(0.0, (a - offset) / rate), max(0.0, (b - offset) / rate)) for a, b in timings]
        if len(audio) == 0 or not np.isfinite(audio).all() or not np.any(audio):
            raise RuntimeError("Invalid generated speech")
        if len(audio) > rate * 90:
            raise RuntimeError("Unexpectedly long chunk")
        return audio, rate, timings

    @staticmethod
    def wav(np, audio, rate):
        pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
        output = io.BytesIO()
        with wave.open(output, "wb") as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(rate)
            file.writeframes(pcm.tobytes())
        return output.getvalue()


def align_words(text, spans, timings, duration, count_spoken=None):
    """Gives every text word a (start, end) time.

    Uses the model's per-word timings when the word counts match. When they don't
    (numbers and abbreviations become several spoken words), count_spoken(word)
    says how many spoken words each text word became. Otherwise the speech is
    spread across the words by length.
    """
    def clamp(a, b):
        return min(a, duration), min(max(b, a), duration)

    if timings and len(timings) == len(spans):
        return [clamp(a, b) for a, b in timings]
    if timings and count_spoken is not None:
        counts = [count_spoken(text[s:e]) for s, e in spans]
        if sum(counts) == len(timings):
            result, index = [], 0
            for count in counts:
                if count == 0:
                    edge = timings[index][0] if index < len(timings) else timings[-1][1]
                    result.append(clamp(edge, edge))
                else:
                    result.append(clamp(timings[index][0], timings[index + count - 1][1]))
                    index += count
            return result
    start, end = (timings[0][0], timings[-1][1]) if timings else (0.0, duration)
    end = min(max(end, start + 0.01), duration)
    weights = [e - s + 1 for s, e in spans]
    total = sum(weights)
    result, cursor = [], start
    for weight in weights:
        length = (end - start) * weight / total
        result.append((cursor, cursor + length))
        cursor += length
    return result


class Service:
    def __init__(self, engine, root, emit=reply):
        self.engine = engine
        self.root = root
        self.emit = emit
        self.condition = threading.Condition()
        self.jobs = deque()
        self.current = None
        self.closed = False
        self.selected = self.read_selection()
        self.thread = threading.Thread(target=self.work, name="local-kokoro-inference", daemon=True)
        self.thread.start()

    def read_selection(self):
        try:
            settings = json.loads((self.root / "settings.json").read_text())
            if not isinstance(settings, dict):
                return None
            return settings.get("selectedVoice") if settings.get("selectedVoice") in self.engine.voices else None
        except (OSError, ValueError):
            return None

    def fail(self, rpc_id, code):
        self.emit({"rpcId": rpc_id, "error": {"code": code, "message": code}})

    def handle(self, command):
        rpc_id = command.get("rpcId")
        action = command.get("action")
        if not isinstance(rpc_id, int) or isinstance(rpc_id, bool) or rpc_id < 1:
            return
        if action == "voices":
            self.emit({"rpcId": rpc_id, "result": self.engine.metadata(self.selected)})
            return
        if action == "set_voice":
            voice = command.get("voice")
            if voice not in self.engine.voices:
                self.fail(rpc_id, "INVALID_VOICE")
                return
            temporary = self.root / "settings.json.new"
            with temporary.open("w") as file:
                os.fchmod(file.fileno(), 0o600)
                json.dump({"version": 1, "selectedVoice": voice}, file)
                file.write("\n")
            temporary.replace(self.root / "settings.json")
            self.selected = voice
            self.emit({"rpcId": rpc_id, "result": {"selectedVoice": voice}})
            return
        request_id = command.get("requestId")
        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128:
            self.fail(rpc_id, "INVALID_REQUEST")
            return
        with self.condition:
            if action == "cancel":
                if self.current and self.current["id"] == request_id:
                    self.current = None
                self.emit({"rpcId": rpc_id, "result": {"done": True}})
                return
            if action == "start":
                text = command.get("text")
                voice = command.get("voice", self.selected)
                speed = command.get("speed", 1.0)
                if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
                    self.fail(rpc_id, "INVALID_TEXT")
                    return
                if any(0xD800 <= ord(c) <= 0xDFFF for c in text):
                    self.fail(rpc_id, "INVALID_TEXT")
                    return
                if (not isinstance(speed, (int, float)) or isinstance(speed, bool) or
                        not MIN_SPEED <= speed <= MAX_SPEED):
                    self.fail(rpc_id, "INVALID_SPEED")
                    return
                if voice is None:
                    self.fail(rpc_id, "VOICE_NOT_SELECTED")
                    return
                if voice not in self.engine.voices:
                    self.fail(rpc_id, "INVALID_VOICE")
                    return
                self.current = {"id": request_id, "text": text, "voice": voice, "speed": float(speed),
                                "chunks": None, "utf16": None}
                # Superseded queued work never runs; the active chunk may finish.
                while self.jobs:
                    stale_rpc, _ = self.jobs.popleft()
                    self.fail(stale_rpc, "CANCELED")
            elif action != "next":
                self.fail(rpc_id, "INVALID_ACTION")
                return
            context = self.current
            if context is None or context["id"] != request_id:
                self.fail(rpc_id, "CANCELED")
                return
            if len(self.jobs) >= 2:
                self.fail(rpc_id, "BUSY")
                return
            self.jobs.append((rpc_id, context))
            self.condition.notify()

    def next_result(self, context):
        if context["chunks"] is None:
            context["chunks"] = self.engine.chunks(context["text"], context["voice"])
            context["utf16"] = utf16_offsets(context["text"])
        try:
            spans, phonemes = next(context["chunks"])
        except StopIteration:
            return {"done": True}
        offsets = context["utf16"]
        result = {"done": False, "textStart": offsets[spans[0][0]], "textEnd": offsets[spans[-1][1]]}
        if not phonemes:
            result["skipped"] = True
            return result
        np = self.engine.np
        audio, rate, timings = self.engine.render(phonemes, context["voice"], context["speed"])
        language = "en-gb" if context["voice"][0] == "b" else "en-us"
        count = lambda word: len(phoneme_word_spans(self.engine.tokenizer.phonemize(word, language)))
        words = align_words(context["text"], spans, timings, len(audio) / rate, count)
        result.update({
            "audioBase64": base64.b64encode(Engine.wav(np, audio, rate)).decode("ascii"),
            "mimeType": "audio/wav",
            "words": [[offsets[s], offsets[e], round(float(a), 3), round(float(b), 3)]
                      for (s, e), (a, b) in zip(spans, words)],
        })
        return result

    def work(self):
        while True:
            with self.condition:
                self.condition.wait_for(lambda: self.jobs or self.closed)
                if self.closed:
                    return
                rpc_id, context = self.jobs.popleft()
                if self.current is not context:
                    self.fail(rpc_id, "CANCELED")
                    continue
            try:
                result = self.next_result(context)
                with self.condition:
                    if self.current is not context:
                        self.fail(rpc_id, "CANCELED")
                    else:
                        if result["done"]:
                            self.current = None
                        self.emit({"rpcId": rpc_id, "result": result})
            except Exception:
                with self.condition:
                    canceled = self.current is not context
                    if not canceled:
                        self.current = None
                self.fail(rpc_id, "CANCELED" if canceled else "SPEECH_FAILED")

    def close(self):
        with self.condition:
            self.closed = True
            self.current = None
            self.condition.notify()


def main():
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    try:
        engine = Engine(ROOT)
    except Exception:
        reply({"event": "fatal", "error": {"code": "RUNTIME_UNAVAILABLE"}})
        return 1
    service = Service(engine, ROOT)
    reply({"event": "ready", "engine": engine.kind, "protocolVersion": PROTOCOL_VERSION})
    try:
        for line in sys.stdin:
            if len(line) > 1500000:
                return 1
            command = None
            try:
                command = json.loads(line)
                if not isinstance(command, dict):
                    continue
                service.handle(command)
            except Exception:
                # Never echo response text or exception messages to logs.
                if isinstance(command, dict):
                    rpc_id = command.get("rpcId")
                    if isinstance(rpc_id, int):
                        error(rpc_id, "INVALID_REQUEST")
    finally:
        service.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
