# OpenOats

OpenOats records a meeting on a Mac and turns it into a markdown file: notes on top, a You/Them transcript underneath.

## Meetings

**Meeting**:
One recorded conversation, from Start to Stop, and everything produced from it.
_Avoid_: Session, call, recording (when you mean the whole thing)

**Mic track**:
The audio captured from the user's microphone during a Meeting.
_Avoid_: Input, local audio

**System track**:
The audio the Mac played during a Meeting, i.e. the other participants.
_Avoid_: Output, remote audio, speaker audio

**You**:
The speaker label for everything transcribed from the Mic track.
_Avoid_: Me, local speaker

**Them**:
The speaker label for everything transcribed from the System track.
_Avoid_: Others, remote speaker

**Meeting file**:
The single markdown file a Meeting produces, containing frontmatter, Notes, and the Transcript.
_Avoid_: Note, export, document

**Transcript**:
The timestamped, speaker-labelled text of what was said, in the Meeting file.

**Notes**:
The model-written summary of a Meeting (summary, decisions, action items) at the top of the Meeting file.
_Avoid_: Summary (when you mean the whole section), minutes

## Processing

**Processing**:
The work done after Stop that turns a Meeting's tracks into its Meeting file.
_Avoid_: Post-processing, finalization, batch pass

**Transcription backend**:
Whatever turns a track's audio into text: on-device by default, or a configured cloud or self-hosted service.
_Avoid_: ASR engine, transcription model (when you mean the provider)

**Notes backend**:
The language model that writes the Notes and corrects Vocabulary in the Transcript. Optional; none by default.
_Avoid_: LLM provider, AI

**Preset**:
A named starting configuration for a backend (e.g. Ollama, OpenRouter) that fills in its address and default model.
_Avoid_: Provider, integration

**Vocabulary**:
The user's list of names and terms that the Transcript should spell correctly.
_Avoid_: Custom words, dictionary, keywords
