# OpenOats

**A meeting note-taker that talks back — now on Windows and Mac.**

<p align="center">
  <a href="https://github.com/romeroej2/OpenOats/releases/latest">
    <img src="https://img.shields.io/badge/Download_for_Mac-DMG-black?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" />
  </a>
  <a href="https://github.com/romeroej2/OpenOats/releases/latest">
    <img src="https://img.shields.io/badge/Download_for_Windows-EXE-black?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows" />
  </a>
</p>

OpenOats sits next to your call, transcribes both sides of the conversation in real time, and searches your own notes to surface talking points right when you need them.

<p align="center">
  <img src="assets/screenshot.png" width="360" alt="OpenOats during a call — suggestions drawn from your own notes appear at the top, live transcript below" />
</p>

---

## Features

- **Invisible to the other side** — the overlay window is hidden from screen sharing by default, so no one knows you're using it
- **Fully offline transcription** — speech recognition runs on your machine; no audio ever leaves your device
- **Runs 100% locally** — pair with [Ollama](https://ollama.com/) for LLM suggestions and local embeddings, and nothing touches the network at all
- **Pick any LLM** — use [OpenRouter](https://openrouter.ai/) for cloud models (GPT-4o, Claude, Gemini) or Ollama for local ones (Llama, Qwen, Mistral)
- **Live transcript** — see both sides of the conversation as it happens, copy the whole thing with one click
- **Smart suggestions** — when the conversation hits a moment that matters, OpenOats pulls in relevant talking points from your notes
- **Auto-generated notes** — after each session, produce structured markdown notes from the transcript using meeting templates (1:1, stand-up, customer discovery, and more)
- **Auto-saved sessions** — every conversation is automatically saved as a plain-text transcript and a structured session log, no manual export needed
- **Knowledge base search** — point it at a folder of notes and it retrieves what's relevant using [Voyage AI](https://www.voyageai.com/) embeddings, local Ollama embeddings, or any OpenAI-compatible endpoint

---

## How it works

1. You start a call and click **Start Session**
2. OpenOats captures your microphone and (on Windows) system audio — the other side's voice is captured as "them"
3. When the conversation hits a moment that matters — a question, a decision point, a claim worth backing up — it searches your notes and surfaces relevant talking points
4. After the session, generate structured markdown notes from the transcript using a meeting template
5. You sound prepared because you are

---

## Downloads

Grab the latest release for your platform from the [Releases page](https://github.com/romeroej2/OpenOats/releases/latest).

Or build from source.

### Build from source

**Requirements:**
- [Rust](https://rustup.rs/) (latest stable)
- [Node.js](https://nodejs.org/) 18+
- Xcode Command Line Tools (macOS only)

```bash
# Clone the repo
git clone https://github.com/romeroej2/OpenOats.git
cd OpenOats

# Build the Tauri app
cd OpenOatsTauri
npm install
cargo tauri build
```

The installers are output to `OpenOatsTauri/src-tauri/target/release/bundle/`.

---

## What you need

### Windows

- Windows 10 or 11 (64-bit)
- **For cloud mode**: [OpenRouter](https://openrouter.ai/) API key + [Voyage AI](https://www.voyageai.com/) API key
- **For local mode**: [Ollama](https://ollama.com/) running locally with your preferred models (e.g. `qwen3:8b` for suggestions, `nomic-embed-text` for embeddings)
- **For OpenAI-compatible embeddings**: any server implementing `/v1/embeddings` (llama.cpp, LiteLLM, vLLM, etc.)

### macOS

- Apple Silicon Mac, macOS 15+
- **For cloud mode**: OpenRouter + Voyage AI API keys
- **For local mode**: Ollama

---

## Quick start

1. Open the app and grant microphone permissions
2. Open Settings (`Cmd+,` or `Ctrl+,`) and pick your providers:
   - **Cloud**: add your OpenRouter and Voyage AI API keys
   - **Local**: select Ollama as your LLM and embedding provider (make sure Ollama is running)
   - **OpenAI-compatible**: select "OpenAI Compatible" as your embedding provider and point it at any `/v1/embeddings` endpoint
3. Point it at a folder of `.md` or `.txt` files — that's your knowledge base
4. Click **Start Session** to go live

The first run downloads the local Whisper speech model (~600 MB).

---

## Architecture

OpenOats is built on a cross-platform Rust core with a shared React frontend.

```
OpenOats/                        # Cargo workspace root
├── crates/
│   └── openoats-core/           # Shared Rust library — all business logic
│       └── src/
│           ├── models.rs        # Utterance, Speaker, Session, Suggestion, ConversationState, etc.
│           ├── settings.rs      # AppSettings (JSON persistence)
│           ├── keychain.rs      # Secret storage (Windows Credential Manager / macOS Keychain)
│           ├── audio/           # Audio capture traits and implementations
│           ├── transcription/   # VAD + Whisper transcription pipeline
│           ├── storage/         # Session persistence (JSONL) + transcript logging
│           └── intelligence/    # LLM client, embedding client, knowledge base, suggestion engine
│
├── OpenOatsTauri/               # Tauri app (Windows + macOS)
│   ├── src-tauri/
│   │   ├── src/
│   │   │   ├── lib.rs          # Tauri commands — thin bridge to openoats-core
│   │   │   ├── main.rs         # Entry point
│   │   │   ├── engine.rs       # Session orchestration + Tauri event emission
│   │   │   └── audio_windows.rs # WASAPI loopback (system audio capture)
│   │   └── tauri.conf.json
│   └── src/                     # React/TypeScript UI
│       ├── App.tsx
│       └── components/
│           ├── ControlBar.tsx
│           ├── TranscriptView.tsx
│           ├── SuggestionsView.tsx
│           ├── NotesView.tsx
│           └── SettingsView.tsx
│
├── Sources/
│   ├── OpenOatsCore/           # Swift core (legacy — being replaced)
│   ├── OpenOatsMac/            # Native Mac app (legacy — being replaced)
│   └── OpenOatsWindows/       # Windows Swift stubs (legacy — being replaced)
│
└── Package.swift                # Swift package definition (legacy)
```

### Key technologies

| Component | Technology |
|---|---|
| App framework | [Tauri 2](https://tauri.app/) |
| Core logic | Rust (`openoats-core`) |
| Transcription | [whisper-rs](https://github.com/ubisoft/Voxxiamo#whisper-rs) (Whisper.cpp bindings) |
| Audio capture | cpal (mic), WASAPI (Windows system audio) |
| LLM inference | OpenRouter API or [Ollama](https://ollama.com/) |
| Embeddings | Voyage AI, Ollama, or any OpenAI-compatible endpoint |
| Frontend | React 18 + TypeScript + Vite |
| Secret storage | Windows Credential Manager / macOS Keychain |

---

## Privacy

- Speech is transcribed locally — audio never leaves your machine
- **With Ollama**: everything stays on your device. Zero network calls.
- **With cloud providers**: KB chunks are sent to Voyage AI (or your chosen OpenAI-compatible endpoint) for embedding (text only, no audio), and conversation context is sent to OpenRouter for suggestions
- API keys are stored in your system's credential manager (Windows Credential Manager or macOS Keychain)
- The overlay window is hidden from screen sharing by default
- Transcripts are saved locally to `~/Documents/OpenOats/`

---

## Recording Consent & Legal Disclaimer

**Important:** OpenOats records and transcribes audio from your microphone and system audio. Many jurisdictions have laws requiring consent from some or all participants before a conversation may be recorded (e.g., two-party/all-party consent states in the U.S., GDPR in the EU).

**By using this software, you acknowledge and agree that:**

- **You are solely responsible** for determining whether recording is lawful in your jurisdiction and for obtaining any required consent from all participants before starting a session.
- **The developers and contributors of OpenOats provide no legal advice** and make no representations about the legality of recording in any jurisdiction.
- **The developers accept no liability** for any unauthorized or unlawful recording conducted using this software.

**Do not use this software to record conversations without proper consent where required by law.**

The app will ask you to acknowledge these obligations before your first recording session.

---

## License

MIT
