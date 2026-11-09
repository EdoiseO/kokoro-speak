# Kokoro Speak

Read selected text aloud on your Mac with [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), a natural-sounding text-to-speech model that runs entirely on your machine.

Select text in any app and press **⌥ Esc**. Press it again to stop.

- **Runs locally.** The model runs on your Mac's GPU, and the speech process is blocked from the network.
- **Lightweight.** It's a small native menu bar app (about 20 MB of memory). The model (about 335 MB) loads when you start speaking and unloads after 5 idle minutes.
- **No pauses.** Each chunk of speech is generated while the previous one plays.
- **Follow along.** A floating mini player shows the sentence being read and highlights each word as it's spoken, in yellow or light blue.
- **28 voices** in American and British English, with four speeds.

## Requirements

- An Apple silicon Mac (M1 or later) running macOS 13 or later
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.13: `brew install python@3.13`
- About 1 GB of disk space

## Install

```bash
git clone https://github.com/EdoiseO/kokoro-speak.git
cd kokoro-speak
./install.sh
```

The installer:

1. creates a Python environment from exact, hash-pinned wheels (`runtime/requirements.lock`)
2. downloads the model and voice files (about 355 MB) and checks their SHA-256 hashes (`runtime/models.json`)
3. generates a test clip with network access blocked
4. builds the app into `~/Applications/Kokoro Speak.app`
5. binds **⌥ Esc** to the app's "Speak with Kokoro Speak" service

You can run it again at any time. Steps that are already done are skipped.

If another service already uses ⌥ Esc (for example the built-in Speak Selection, which is set in System Settings > Accessibility > Spoken Content), the installer tells you. Change one of them in System Settings > Keyboard > Keyboard Shortcuts > Services.

## Use

| Action | How |
| --- | --- |
| Speak selected text | Select text, press ⌥ Esc |
| Stop | Press ⌥ Esc again, click the menu bar icon, or click × in the mini player |
| Pause, skip a sentence | Right-click the menu bar icon while speaking, or use the mini player's pause button |
| Highlight color, hide the mini player | Menu bar icon > Highlight, Show mini player |
| Pick a voice | Menu bar icon > Voice. Picking a voice plays a short preview |
| Change speed | Menu bar icon > Speed |
| Speak the clipboard | Menu bar icon > Speak clipboard |

The shortcut works anywhere the macOS Services menu works, which includes most apps. Selecting text needs no Accessibility permission.

## How it works

```
⌥ Esc ─▶ macOS Services ─▶ Kokoro Speak.app (Swift, menu bar)
                               │  JSON lines over stdin/stdout
                               ▼
                         worker.py (Python, MLX on the GPU)
                         runs under sandbox-exec with network denied
```

- `app/`: the Swift menu bar app. `Speaker.swift` keeps at most two chunks queued ahead of playback, and `AudioOutput.swift` plays them gaplessly with AVAudioEngine.
- `runtime/worker.py`: splits text into sentence-sized chunks and renders each as 24 kHz audio, with a start and end time for every word. It gets the timings from Kokoro's per-phoneme durations. Its protocol is `start`, `next`, `cancel`, `voices` and `set_voice` requests, one JSON object per line. The details are at the top of the file.
- Each chunk is scheduled at an exact sample position, so the app can map the playback time to the word being spoken.
- Runtime files go in `~/Library/Application Support/Kokoro Speak/`.

### Build only the app

```bash
scripts/build-app.sh      # outputs build/Kokoro Speak.app
```

Set `KOKORO_SPEAK_RUNTIME` to use a runtime directory other than the default one.

## Uninstall

```bash
./uninstall.sh
```

This removes the app, the runtime and model files, and the shortcut.

## Credits and licenses

- Kokoro Speak code: MIT (see `LICENSE`)
- [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) model by hexgrad: Apache 2.0. The MLX weights come from [mlx-community/Kokoro-82M-bf16](https://huggingface.co/mlx-community/Kokoro-82M-bf16)
- Voice file from [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx): MIT
- [mlx-audio](https://github.com/Blaizzy/mlx-audio) and [MLX](https://github.com/ml-explore/mlx): MIT
- The installer also fetches [phonemizer](https://github.com/bootphon/phonemizer) and espeak-ng (through `espeakng-loader`), which are GPL-3.0. They're downloaded onto your Mac at install time and aren't included in this repo.
