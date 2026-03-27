# Demo Scenarios

Set the KB folder in OpenOats Settings to this `demo-kb` directory, then start a session. You'll need a second person on a call (or play audio from another device). The suggestions panel appears on the right.

---

## Scenario 1: Sales Call — Pricing Objection

**Setup:** You're the sales rep. A prospect is evaluating OpenOats for their team.

**Have the other person say things like:**

1. "We've been looking at Otter and Fireflies too. How are you different?"
   - *Expected: suggestion surfaces competitive differentiation — local-first, KB-grounded, real-time vs post-hoc*

2. "Your pricing seems high. Otter is $17 a month."
   - *Expected: surfaces the objection handler — transcription-only vs. KB coaching, ROI argument*

3. "We have about 30 people who'd use this. What kind of deal can you do?"
   - *Expected: surfaces Team plan pricing at $22/seat, annual discount of 20%, floor of $18/seat*

4. "We're already using Gong for our sales team."
   - *Expected: surfaces the Gong complementarity talking point — Gong is post-meeting for managers, OpenOats is in-meeting for reps*

5. "Can we do a longer pilot? Two weeks isn't enough."
   - *Expected: surfaces pilot rules — max 30 days with VP approval, never extend beyond that*

---

## Scenario 2: Investor Update — Metrics Deep Dive

**Setup:** You're the founder presenting to your board/investors.

**Have the other person ask:**

1. "What's your current MRR and how has growth been?"
   - *Expected: surfaces $38.4K MRR, up from $2.8K MAU in January to 4.2K*

2. "What does retention look like? Are people sticking around?"
   - *Expected: surfaces D30 retention cohorts, plus the KB adoption insight (82% vs 34%)*

3. "How does your unit economics look? What's your LTV:CAC?"
   - *Expected: surfaces LTV $310, CAC $42, 7.4x ratio*

4. "What's the biggest risk to the roadmap?"
   - *Expected: surfaces the assignee detection accuracy risk (72% vs 85% target) and the billing migration dependency*

5. "How are you thinking about competition? Is Granola a threat?"
   - *Expected: surfaces Granola comparison — notepad vs copilot, no KB integration, no real-time suggestions*

---

## Scenario 3: Product Review — Prioritization Debate

**Setup:** You're running an internal product meeting with a colleague.

**Have the other person say:**

1. "I think we should prioritize the mobile app over the collaborative KB."
   - *Expected: surfaces user research showing KB setup friction affects 6/12 power users, and KB adoption is the strongest retention predictor*

2. "Users are complaining that suggestions come too late. How bad is it?"
   - *Expected: surfaces the latency data — 18s p50 old pipeline, target <2s, and that 9/12 users mentioned timing as a pain point*

3. "Should we build a browser extension?"
   - *Expected: surfaces the "Explicitly Not Planned" section — macOS-native is the moat, browser would dilute quality*

4. "What's the conversion funnel looking like for trial users?"
   - *Expected: surfaces evaluator research — 73% convert after first valuable suggestion, 41% churn because KB setup takes too long*

5. "Do we have any data on what the video recording feature would take?"
   - *Expected: surfaces the "not planned" decision — privacy concerns, storage costs, not differentiation*

---

## Tips for a Good Demo

- **Speak naturally.** Don't read scripts word-for-word — the engine responds to conversational patterns, not exact phrases.
- **Pause briefly after key statements.** Give the engine 1-2 seconds to surface a suggestion before moving on.
- **Point out the source breadcrumbs.** Each suggestion shows where it found the information (e.g., `sales/pricing.md > Common Objections`).
- **Show the streaming.** The suggestion appears as a raw KB snippet instantly, then the LLM synthesizes a concise version that streams in.
- **Toggle with Cmd+Shift+O.** Show that the panel can be hidden and revealed without interrupting the session.
