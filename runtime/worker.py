"""Local, network-denied Kokoro RPC worker. Model and voices are always local.

Protocol: one JSON object per line on stdin/stdout. See README for details.
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
MAX_SENTENCE_RANGES = 4096
PROTOCOL_VERSION = 2
MIN_SPEED = 0.5
MAX_SPEED = 2.0
JS_NON_WHITESPACE = re.compile(r"[^\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]")


def validate_sentence_ranges(text, ranges):
    """Convert exact JS UTF-16 boundaries to Python indices without losing text."""
    if not isinstance(ranges, list) or not 1 <= len(ranges) <= MAX_SENTENCE_RANGES:
        raise ValueError("Invalid sentence ranges")
    boundaries = {0: 0}
    offset = 0
    for index, character in enumerate(text):
        code = ord(character)
        if 0xD800 <= code <= 0xDFFF:
            raise ValueError("Invalid Unicode text")
        offset += 2 if code > 0xFFFF else 1
        if offset > MAX_TEXT:
            raise ValueError("Text is too long")
        boundaries[offset] = index + 1
    converted = []
    previous_end = 0
    previous_python_end = 0
    for item in ranges:
        if not isinstance(item, dict):
            raise ValueError("Invalid sentence range")
        start, end = item.get("start"), item.get("end")
        if (not isinstance(start, int) or isinstance(start, bool) or
                not isinstance(end, int) or isinstance(end, bool) or
                start < previous_end or start < 0 or start >= end or
                start not in boundaries or end not in boundaries):
            raise ValueError("Invalid sentence boundary")
        python_start, python_end = boundaries[start], boundaries[end]
        if JS_NON_WHITESPACE.search(text[previous_python_end:python_start]) or not JS_NON_WHITESPACE.search(text[python_start:python_end]):
            raise ValueError("Sentence ranges do not cover text")
        converted.append((start, end, python_start, python_end))
        previous_end, previous_python_end = end, python_end
    if JS_NON_WHITESPACE.search(text[previous_python_end:]):
        raise ValueError("Sentence ranges do not cover text")
    return converted


def reply(value):
    with OUTPUT_LOCK:
        PROTOCOL.write(json.dumps(value, separators=(",", ":")) + "\n")
        PROTOCOL.flush()


def error(rpc_id, code="SPEECH_FAILED"):
    reply({"rpcId": rpc_id, "error": {"code": code, "message": code}})


def phoneme_chunks(phonemes, first_limit=180, next_limit=350):
    """Keep every non-whitespace phoneme, prefer sentence/word boundaries."""
    original = " ".join(phonemes.split())
    remaining = original
    chunks = []
    while remaining:
        limit = first_limit if not chunks else next_limit
        if len(remaining) <= limit:
            chunks.append(remaining)
            break
        head = remaining[:limit]
        punctuation = max(head.rfind(mark) for mark in (". ", "! ", "? ", "; ", ": "))
        space = head.rfind(" ")
        cut = punctuation + 1 if punctuation >= 60 else space if space >= 40 else limit
        chunks.append(remaining[:cut].strip())
        remaining = remaining[cut:].lstrip()
    if "".join(chunks).replace(" ", "") != original.replace(" ", ""):
        raise RuntimeError("Phoneme content changed during splitting")
    return [chunk for chunk in chunks if chunk]


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
        return {"voices": [{"id": v, "name": v.split("_", 1)[1].replace("_", " ").title(), "lang": "en-GB" if v[0] == "b" else "en-US"} for v in self.voices], "selectedVoice": selected, "speed": 1, "engine": self.kind}

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

    def prepare(self, text, voice):
        self.load()
        language = "en-gb" if voice[0] == "b" else "en-us"
        phonemes = self.tokenizer.phonemize(text, language)
        return iter(phoneme_chunks(phonemes))

    def render(self, phonemes, voice, speed=1.0):
        np = self.np
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
            generated = self.model(known, ref, speed=speed)
            mx.eval(generated)
            audio = np.array(generated.reshape(-1).astype(mx.float32))
            del generated, ref
            mx.clear_cache()
            from kokoro_onnx.trim import trim
            audio, _ = trim(audio)
            rate = 24000
        if len(audio) == 0 or not np.isfinite(audio).all() or not np.any(audio):
            raise RuntimeError("Invalid generated speech")
        if len(audio) > rate * 90:
            raise RuntimeError("Unexpectedly long chunk")
        pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(pcm.tobytes())
        return {"done": False, "audioBase64": base64.b64encode(output.getvalue()).decode("ascii"), "mimeType": "audio/wav"}


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
        if "sentenceRanges" in command and action != "start":
            self.fail(rpc_id, "INVALID_SENTENCE_RANGES")
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
            with self.condition:
                self.current = None
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
                if (not isinstance(speed, (int, float)) or isinstance(speed, bool) or
                        not MIN_SPEED <= speed <= MAX_SPEED):
                    self.fail(rpc_id, "INVALID_SPEED")
                    return
                if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
                    self.fail(rpc_id, "INVALID_TEXT")
                    return
                try:
                    sentence_ranges = validate_sentence_ranges(text, command["sentenceRanges"]) if "sentenceRanges" in command else None
                except (ValueError, TypeError):
                    self.fail(rpc_id, "INVALID_SENTENCE_RANGES")
                    return
                if voice is None:
                    self.fail(rpc_id, "VOICE_NOT_SELECTED")
                    return
                if voice not in self.engine.voices:
                    self.fail(rpc_id, "INVALID_VOICE")
                    return
                self.current = {"id": request_id, "text": text, "voice": voice, "chunks": None, "sentence_ranges": sentence_ranges, "speed": float(speed)}
                # Superseded queued work never runs; the active batch may finish.
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

    def prepare_chunks(self, context, text):
        """Tokenize only the sentence whose next audio chunk is requested."""
        ranges = context["sentence_ranges"]
        pieces = [(None, None, 0, len(text))] if ranges is None else ranges
        for start, end, python_start, python_end in pieces:
            with self.condition:
                if self.current is not context:
                    return
            had_phonemes = False
            for phonemes in self.engine.prepare(text[python_start:python_end], context["voice"]):
                with self.condition:
                    if self.current is not context:
                        return
                had_phonemes = True
                yield phonemes, start, end
            if not had_phonemes and start is not None:
                # The tokenizer may omit symbols entirely. Report that exact
                # approved sentence as silent instead of jumping over it.
                with self.condition:
                    if self.current is not context:
                        return
                yield None, start, end

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
                if context["chunks"] is None:
                    context["chunks"] = self.prepare_chunks(context, context["text"])
                    context["text"] = ""
                with self.condition:
                    if self.current is not context:
                        self.fail(rpc_id, "CANCELED")
                        continue
                try:
                    phonemes, sentence_start, sentence_end = next(context["chunks"])
                except StopIteration:
                    result = {"done": True}
                else:
                    result = ({"done": False, "skipped": True} if phonemes is None
                              else self.engine.render(phonemes, context["voice"], context["speed"]))
                    if sentence_start is not None:
                        result["sentenceStart"] = sentence_start
                        result["sentenceEnd"] = sentence_end
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
