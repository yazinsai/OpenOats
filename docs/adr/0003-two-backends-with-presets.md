# Two backend slots, configured by protocol with presets

Users run models everywhere: on-device, cloud APIs, Ollama, LM Studio, llama.cpp, Tailscale-hosted boxes. 1.x had a dedicated code path per provider (8 LLM, 10 transcription). v2 has exactly two slots, the Transcription backend and the Notes backend, each implemented by a small number of protocol types: Notes is none, OpenAI-compatible, Anthropic, or Gemini; Transcription is on-device, OpenAI-style transcription endpoint, ElevenLabs, AssemblyAI, or Gemini. Named Presets (OpenAI, OpenRouter, Requesty, Ollama, LM Studio, MLX, llama.cpp…) only fill in address and default model, so supporting a new provider is data, not code. Defaults are on-device transcription and no Notes backend, so the typical user never opens these settings.

## Consequences

On-device transcription ships two models, chosen automatically by language: Parakeet v3 for its 25 European languages and Whisper large-v3-turbo for everything else. Bark+, Qwen3, Parakeet v2, small Whisper models and Cohere Arabic are dropped.
