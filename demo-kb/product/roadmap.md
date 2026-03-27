# Product Roadmap — Q2 2026

## Released (Q1)

- Real-time suggestion panel with streaming LLM synthesis
- Multi-speaker diarization (LS-EEND)
- Batch transcript refinement with Parakeet TDT v3
- Session tagging and organization

## In Progress (Q2)

### Meeting Intelligence v2 — Target: April 15
- Auto-generated action items with assignee detection
- Follow-up email drafts from meeting context
- Slack/Teams integration for action item push
- Risk: Assignee detection accuracy is ~72% on internal benchmarks; need 85%+ before shipping

### Collaborative KB — Target: May 30
- Shared knowledge bases across team members
- KB contribution tracking (who added what)
- Conflict resolution for overlapping KB entries
- Dependency: Requires Team plan billing migration (backend team, ETA April 20)

### Mobile Companion — Target: June 15
- iOS app for meeting playback and note review
- Push notifications for action items
- No recording capability on mobile (privacy decision, not technical limitation)

## Planned (Q3)

- Calendar integration (Google Calendar, Outlook) for auto-start
- Custom meeting templates with structured extraction
- Analytics dashboard for meeting patterns
- Whisper-based multilingual transcription (beyond Parakeet's English focus)

## Explicitly Not Planned

- Video recording (privacy concerns, storage costs, not our differentiation)
- Real-time translation (interesting but orthogonal to our core value prop)
- Browser extension (macOS-native is our moat; browser would dilute quality)
