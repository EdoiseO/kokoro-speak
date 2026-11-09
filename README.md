# Kokoro Speak

Read selected text aloud on your Mac with [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), a natural-sounding text-to-speech model that runs entirely on your machine.

Select text in any app and press **⌥ Esc**. Press it again to stop.

- **Runs locally.** The model runs on your Mac's GPU, and the speech process is blocked from the network.
- **Lightweight.** It's a small native menu bar app (about 20 MB of memory). The model (about 335 MB) loads when you start speaking and unloads after 5 idle minutes.
- **No pauses.** Each chunk of speech is generated while the previous one plays.
- **Follow along.** A floating mini player shows the sentence being read and highlights each word as it's spoken, in light blue (the default) or yellow.
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
5. opens the app, which registers **⌥ Esc** as a global shortcut

You can run it again at any time. Steps that are already done are skipped.

The first time you press ⌥ Esc, macOS asks you to allow Kokoro Speak in **System Settings > Privacy & Security > Accessibility**. This lets it read the text you've selected in other apps. Turn it on, then press ⌥ Esc again.

The installer creates a self-signed certificate called "Kokoro Speak Local Signing" in your login keychain and signs the app with it (`scripts/make-signing-cert.sh`). Because every build is signed with the same certificate, macOS keeps the permission when you update. The certificate never leaves your Mac. To remove it, run `security delete-identity -c "Kokoro Speak Local Signing"`.

If the built-in Speak Selection also uses ⌥ Esc (System Settings > Accessibility > Spoken Content), change one of them.

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

Kokoro Speak reads the selection through the macOS Accessibility API. If an app doesn't expose its selection that way, it presses ⌘C for you, reads the copied text, and then puts your clipboard back. You can also select text, then choose **Services > Speak with Kokoro Speak** from the app menu or the right-click menu.

## How it works

```
⌥ Esc (global hotkey) ─▶ Kokoro Speak.app (Swift, menu bar) ─▶ reads the selection
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
