# OpenCassava

<p align="center">
  <img src="assets/opencassava_logo.png" width="128" alt="OpenCassava Logo" />
</p>

**A meeting note-taker that talks back — now on Windows and Mac.**

> **Disclaimer & Acknowledgement:** OpenCassava is a descendant of the excellent [OpenOats](https://github.com/yazinsai/OpenOats) project created by [yazinsai](https://github.com/yazinsai). A huge thank you to the original creator for laying the groundwork for this application. OpenCassava has now evolved into its own dedicated project with a focus on comprehensive cross-platform support and expanded features.

<p align="center">
 
  <a href="https://github.com/romeroej2/OpenCassava/releases/latest">
    <img src="https://img.shields.io/badge/Download_for_Windows-EXE-black?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows" />
  </a>
</p>

OpenCassava sits next to your call, transcribes both sides of the conversation in real time, and searches your own notes to surface talking points right when you need them.

For first-time setup with LM Studio, start here: [LM Studio Setup Guide](docs/lm-studio-setup.md)

<p align="center">
  <img src="assets/image.png" width="360" alt="OpenCassava during a call — suggestions drawn from your own notes appear at the top, live transcript below" />
</p>

---

## Features

- **Invisible to the other side** — the overlay window is hidden from screen sharing by default, so no one knows you're using it.
- **Multi-language transcription** — supports both `whisper-rs` and [NVIDIA Parakeet](https://github.com/NVIDIA/NeMo) (25+ languages) for local, offline speech recognition; no audio ever leaves your device.
- **Runs 100% locally** — tested primarily with LM Studio for LLM suggestions and local embeddings. It may also work with other local providers like [Ollama](https://ollama.com/), ensuring nothing touches the network at all.
- **Flexible AI Integration** — pick any LLM. Use [OpenRouter](https://openrouter.ai/) for cloud models (GPT-4o, Claude, Gemini). *(Note: The Cloud AI version is currently untested, but will be reviewed at a later time).*
- **Live transcript & Search** — see both sides of the conversation as it happens, search the active transcript in real-time, and copy or export the whole thing with one click.
- **Session History** — automatically saves every session. Access your past sessions directly from the **History Sidebar**.
- **Auto-summarize during calls** — enable periodic meeting summary generation with live diff highlighting showing what's new. Configure the interval (30s to 10m), review summary history, and manually regenerate at any time.
- **Customizable note & suggestion prompts** — create and edit custom note templates beyond the built-in presets. Fine-tune the system prompts used for knowledge base surfacing, suggestion synthesis, and smart question generation.
- **Formatted Notes generation** — after each session, produce structured markdown notes from the transcript using your custom or built-in templates.
- **Knowledge base search** — point it at a folder of notes and it retrieves what's relevant using Voyage AI embeddings, local Ollama embeddings, or any OpenAI-compatible endpoint.

---

## How it works

1. You start a call and click **Start Session**.
2. OpenCassava captures your microphone and (on Windows & Mac) system audio — the other side's voice is captured as "them".
3. When the conversation hits a moment that matters — a question, a decision point, a claim worth backing up — it searches your notes and surfaces relevant talking points.
4. After the session, use the **Export** menu to save your transcript, or generate structured markdown notes using a meeting template.
5. Review your past transcripts securely using your Session History.

---

## Downloads

Grab the latest release for your platform from the [Releases page](https://github.com/romeroej2/OpenCassava/releases/latest).

Windows releases are built automatically by GitHub Actions from `.github/workflows/windows-release.yml`. On every tag push, the pipeline publishes installers (EXE/MSI).

### Build from source

**Requirements:**
- [Rust](https://rustup.rs/) (latest stable)
- [Node.js](https://nodejs.org/) 18+
- Xcode Command Line Tools (macOS only)

```bash
# Clone the repo
git clone https://github.com/romeroej2/OpenCassava.git
cd OpenCassava

# Build the Tauri app
cd opencassava
npm install
npm run tauri -- build
```

The installers are output to `opencassava/src-tauri/target/release/bundle/`.

---

## What you need

### Windows & macOS

- **OS:** Windows 10/11 (64-bit) or macOS 15+ (Apple Silicon)
- **For local mode (Tested)**: LM Studio (or potentially [Ollama](https://ollama.com/)) running locally with your preferred models (e.g., `qwen3:8b` for suggestions, `nomic-embed-text` for embeddings).
- **For cloud mode (Untested)**: [OpenRouter](https://openrouter.ai/) API key + [Voyage AI](https://www.voyageai.com/) API key.
- **For OpenAI-compatible embeddings**: any server implementing `/v1/embeddings`.

---

## Quick start

1. Open the app and grant microphone permissions (and system audio recording on Windows).
2. Open Settings (`Cmd+,` or `Ctrl+,`) and configure your chosen Cloud or Local providers. *(Note: Cloud mode is currently untested).*
3. Point it at a folder of `.md` or `.txt` files — that's your knowledge base.
4. Click **Start Session** to go live. *(The first run downloads the required local Whisper speech model).*

---

## Architecture

OpenCassava is built on a cross-platform Rust core with a shared React frontend.

| Component | Technology |
|---|---|
| Framework | [Tauri 2](https://tauri.app/) |
| Core logic | Rust (`opencassava-core`) |
| Transcription | [whisper-rs](https://github.com/ubisoft/Voxxiamo#whisper-rs) (Whisper.cpp bindings) |
| Audio capture | cpal (mic), WASAPI (Windows system audio) |
| LLM inference | OpenRouter API or [Ollama](https://ollama.com/) |
| Embeddings | Voyage AI, Ollama, or OpenAI-compatible |
| Frontend UI | React 18 + TypeScript + Vite |
| Secret storage | Windows Credential Manager / macOS Keychain |

---

## Recording Consent & Legal Disclaimer

**Important:** OpenCassava records and transcribes audio from your microphone and system audio. Many jurisdictions have laws requiring consent from some or all participants before a conversation may be recorded. 

**By using this software, you acknowledge and agree that:**
- **You are solely responsible** for determining whether recording is lawful in your jurisdiction and for obtaining any required consent.
- **The developers and contributors of OpenCassava provide no legal advice** and accept no liability for any unauthorized or unlawful recording conducted using this software.

**Do not use this software to record conversations without proper consent where required by law.**

---

## License

MIT
