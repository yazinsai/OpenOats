# User Research Findings — March 2026

## Segment: Power Users (daily use, 30+ meetings/month)

### What They Love
- "The suggestions feel like a cheat code in sales calls" — 8 of 12 interviewees
- KB-backed suggestions are the #1 retention driver; users who set up KB have 3.2x higher 90-day retention
- Transcript accuracy with Parakeet v2 rated "good enough" by 89% of users

### Pain Points
1. **Suggestion timing** (mentioned by 9/12): "Suggestions come too late — by the time it shows up, the conversation has moved on." Average perceived latency: 15-20 seconds. Users want sub-5-second.
2. **Too many irrelevant suggestions** (7/12): "I get suggestions for things I already know. It should learn what I need help with." → Need better duplicate suppression and novelty scoring.
3. **KB setup friction** (6/12): "I had to manually organize my files. Why can't it just watch my Google Drive?" → Collaborative KB and cloud sync are top-requested features.
4. **No mobile access** (5/12): "I take notes on my phone after meetings but can't see the transcript." → Mobile companion app addresses this.

## Segment: Evaluators (trial users, first 2 weeks)

### Why They Convert
- 73% of converters cited "the first time a suggestion saved me in a meeting" as the conversion trigger
- Average time to first valuable suggestion: 3.2 meetings (too slow — need to reduce to 1-2)
- Users who import existing documents to KB convert at 4.1x the rate of those who don't

### Why They Churn
- 41% "didn't have time to set up KB" — onboarding needs to be faster
- 28% "suggestions weren't relevant enough" — cold-start problem without KB
- 18% "privacy concerns about audio capture" — need better consent UX
- 13% "already using another tool" — competitive displacement is hard

## Key Metric Targets

| Metric | Current | Target | Gap |
|--------|---------|--------|-----|
| Suggestion latency (p50) | 18s | <3s | Real-time engine addresses this |
| Suggestion relevance (user rating) | 3.1/5 | 4.0/5 | Better gating + KB matching |
| Time to first value | 3.2 meetings | 1.5 meetings | Onboarding improvements |
| 90-day retention (Pro) | 62% | 75% | Driven by above improvements |
