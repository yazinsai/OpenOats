# OpenOats LM Studio Setup Guide

This guide standardizes the local AI setup for OpenOats using LM Studio for the chat model and embeddings, plus the built-in Whisper download used by OpenOats for transcription.

Important: the current OpenOats backend supports OpenAI-compatible endpoints, which works with LM Studio, but the current Settings screen does not expose an LM Studio preset. For now, the LM Studio path is configured through the app settings file.

## Recommended Setup Stack

Use the following three-model setup:

- LLM in LM Studio: `nvidia/nemotron-3-nano-4b`
- Embeddings in LM Studio: `jina-embeddings-v5-text-small-retrieval`
- Transcription in OpenOats: Whisper `base-en` for English or Whisper `base` for multilingual sessions

## Install OpenOats

If you are using a packaged build, install the latest Windows release. If you are building from source, use the existing repo flow:

```powershell
git clone https://github.com/romeroej2/OpenOats.git
cd OpenOats\OpenOatsTauri
npm install
npm run tauri -- build
```

This repo builds through the local Tauri CLI in `OpenOatsTauri\node_modules`, so `cargo tauri build` is not required unless you separately installed the global `cargo-tauri` subcommand.

On Windows PowerShell, prefer `npm.cmd install` and either `npm.cmd run tauri -- build` or `cmd.exe /d /s /c .\node_modules\.bin\tauri.cmd build` if your `npm` or `npx` shim is misconfigured.

After the app starts for the first time, grant microphone permissions when prompted.

## Install LM Studio

Install LM Studio on the same machine where OpenOats will run.

Recommended process:

- Download and install LM Studio for Windows.
- Launch LM Studio and sign in only if your team workflow requires it.
- Open the model discovery area and download the approved models listed below.

## Download the Recommended Models in LM Studio

### Model A: chat / generation

Download:

```text
nvidia/nemotron-3-nano-4b
```

Use this model for suggestions and notes generation inside OpenOats.

### Model B: embeddings / retrieval

Download:

```text
jina-embeddings-v5-text-small-retrieval
```

Use this model to index the knowledge base and retrieve relevant notes during a call.

### Model C: transcription

Do not download this one in LM Studio. OpenOats downloads Whisper itself on first run.

Recommended default: leave Whisper on `Auto` so English uses `base-en` and other languages use `base`.

## Start the LM Studio Local Server

Load the Nemotron model in LM Studio and enable the local OpenAI-compatible server.

Then load the Jina embeddings model and make sure the embeddings endpoint is available.

In many LM Studio setups, both chat and embeddings are served from the same base URL, typically `http://localhost:1234`.

If your LM Studio configuration uses a different port for embeddings, use that port for the embedding base URL in OpenOats.

## Configure OpenOats for LM Studio

Current limitation: the Settings UI shows Local Mode for Ollama and Cloud Mode for OpenRouter/Voyage. The LM Studio path is already supported in code, but today it must be enabled by editing the settings file directly.

Typical Windows settings path:

```text
C:\Users\<your-user>\AppData\Roaming\OpenOats\settings.json
```

Set or update these values:

```json
{
  "llmProvider": "openai",
  "embeddingProvider": "openai",
  "selectedModel": "nvidia/nemotron-3-nano-4b",
  "openAiLlmBaseUrl": "http://localhost:1234",
  "openAiEmbedBaseUrl": "http://localhost:1234",
  "openAiEmbedModel": "jina-embeddings-v5-text-small-retrieval"
}
```

Notes:

- OpenOats automatically appends `/v1` if it is missing from the base URL.
- API keys for the OpenAI-compatible LM Studio path are optional and can stay blank for local use.
- If LM Studio serves embeddings on a different port, only change `openAiEmbedBaseUrl`.

## Finish Setup Inside the App

- Open OpenOats.
- Verify the microphone input device and, on Windows, the system audio device.
- Choose the folder where notes and transcripts should be stored.
- Choose a Knowledge Base folder containing `.md` or `.txt` notes.
- Wait for the knowledge base to index using the LM Studio embeddings model.
- On first transcription run, allow OpenOats to download the Whisper model it requests.

## Smoke Test Checklist

- Confirm LM Studio is running before starting OpenOats.
- Confirm the local chat endpoint responds.
- Confirm the embeddings endpoint responds.
- Start a short session and verify transcript text appears for both you and them.
- Ask a question that should match one of your knowledge base notes and confirm a suggestion appears.
- Generate notes after the session and confirm the Nemotron model is used without cloud keys.

## Known Constraints

- The backend supports LM Studio through the OpenAI-compatible provider path.
- The current Settings screen does not provide a dedicated LM Studio button or preset.
- Because of that, switching back and forth between Ollama, cloud providers, and LM Studio is currently a settings-file operation.

## Next Steps

Recommended next actions for the project:

- Add an LM Studio preset to the Settings UI so users can choose OpenAI-compatible providers without editing JSON.
- Add a connection test button for both the LLM and embeddings endpoints.
- Add an onboarding screen that explains the three-model setup: LM Studio LLM, LM Studio embeddings, and OpenOats Whisper.
- Save a team-approved sample `settings.json` for faster internal rollout.
- Add a short troubleshooting section for port mismatches, unloaded models, and missing embeddings endpoints.

## Reference Values from the Current Codebase

- OpenAI-compatible LLM default base URL: `http://localhost:1234`
- OpenAI-compatible embedding default base URL: `http://localhost:8080`
- Default local notes folder: `Documents\OpenOats`
- Whisper is downloaded and stored by the app in its app-data directory
