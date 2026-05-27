# Strategy Interview Guide

This guide drives the `ce-strategy` interview. Each section has an opening question and pushback rules. The goal is to produce crisp, testable answers — not marketing copy.

## 1. Target Problem

**Opening:** "What problem does this product solve, and for whom? Be specific."

**Pushback rules:**
- Reject answers that are too broad ("make development easier"). Ask: "For whom, specifically? What's the concrete pain point?"
- Reject feature lists disguised as problems. Ask: "What would users say they can't do today?"
- If the answer could describe 50 other products, push for differentiation: "What's unique about THIS problem or THIS audience?"

**Anti-patterns:**
- "We help teams build better software" → too generic
- "AI-powered workflow optimization" → buzzword soup
- "Like Jira but with AI" → comparison without substance

**Good examples:**
- "Individual developers lose hours context-switching between tools. We reduce that to minutes by keeping the assistant in their editor."
- "Small teams can't afford dedicated QA. We make automated testing accessible to teams of 1-3."

## 2. Our Approach

**Opening:** "What's your unique approach to solving this? What choices are you making that competitors aren't?"

**Pushback rules:**
- Reject answers that describe features ("we have a chatbot"). Ask: "That's WHAT you built. WHY did you choose that approach over alternatives?"
- Push for the constraint or insight: "What did you know or believe that led to this approach?"
- If the answer is "we'll do it better," push: "Better at what, specifically?"

**Anti-patterns:**
- "Best-in-class AI" → no actual choice
- "We listen to users" → everyone says this
- "Fast and reliable" → table stakes, not strategy

**Good examples:**
- "We believe most errors are pattern-matchable, not novel. So we invest in pattern libraries over one-shot reasoning."
- "We optimize for the 80% case — solo devs on small teams — and say no to enterprise features that add complexity."

## 3. Who It's For

**Opening:** "Describe your primary user. Not a demographic — a specific person with a specific situation."

**Pushback rules:**
- Reject "developers" as too broad. Ask: "Which developers? Junior? Senior? Frontend? DevOps? At what company size?"
- Push for situation, not just role: "What were they doing right before they needed this?"
- If the answer lists multiple personas, ask: "If you had to pick ONE primary user, who would it be?"

**Anti-patterns:**
- "Anyone who writes code"
- "Engineering teams of all sizes"
- "Developers and managers"

**Good examples:**
- "A senior IC at a 5-20 person startup who owns features end-to-end and has no dedicated QA or DevOps."
- "A technical founder who codes but can't afford to spend 2 hours on configuration."

## 4. Key Metrics

**Opening:** "How will you know this is working? Name 2-3 metrics you track."

**Pushback rules:**
- Reject vanity metrics ("stars on GitHub"). Ask: "What number, if it moved, would change your decisions?"
- Push for leading indicators, not just lagging: "What can you measure THIS WEEK that predicts success?"
- If metrics are all usage-based, ask: "What about quality or satisfaction?"

**Acceptable:** "We track daily active users, time-to-first-value, and 7-day retention."

## 5. Tracks

**Opening:** "What are the 2-4 big areas of investment right now? These aren't features — they're strategic bets."

**Pushback rules:**
- Reject feature lists ("add dark mode, fix login"). Ask: "What's the THEME? What capability are you building toward?"
- Push for coherence: "How do these tracks support each other? Or are they independent bets?"
- Each track needs a one-line hypothesis: "We believe X will drive Y."

**Anti-patterns:**
- "Improve performance" → too vague. What kind? For whom? To what end?
- "Add more integrations" → what capability does that unlock?

**Good examples:**
- "Reliability foundation: We believe eliminating silent failures will increase daily active users by reducing trust-eroding errors."
- "Onboarding velocity: We believe reducing time-to-first-value from 30min to 5min will double conversion."

## 6. Milestones (optional)

Only include if the user has concrete, dated commitments. Otherwise skip.

## 7. Not Working On (optional)

Only include if there are common requests the team is explicitly deferring. Helps downstream skills avoid wasted exploration.

## 8. Marketing (optional)

Only include if the product has a marketing site, positioning, or launch strategy worth recording.
