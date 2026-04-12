---
date: 2026-04-09
topic: vault-auto-organizer
---

# Vault Auto-Organizer

## What We're Building

A Python script that runs as a NixOS systemd timer on storage, polling Stash for new unorganized scenes and automatically applying metadata using a two-stage pipeline: Stash Identify (StashDB + TPDB) first, then an LLM via OpenRouter for scenes that no scraper could match. FileMonitor plugin already handles file-change detection and Stash scanning; this script handles everything after scan.

## Why This Approach

- **Stash Identify first**: TPDB NAME scrape (already proven to handle ~80% of the library) catches the bulk. This is triggered via GraphQL `metadataIdentify` with existing configuration.
- **LLM fallback via OpenRouter**: For edge cases (Erika Lust series/compilations, Ersties, amateur/OnlyFans content, etc.), the LLM parses the filename directly into structured metadata. No URL scraping needed — the filename already contains studio, title, year, tags, language in most cases.
- **OpenRouter over direct provider APIs**: One API key, flexible model choice. Can start with a cheap model (e.g. Gemini Flash, GPT-4.1-mini, Claude Haiku) for filename parsing and upgrade if quality is insufficient.
- **FileMonitor for detection**: Already installed and working. No need to build custom file watchers.
- **Polling over events**: Script runs daily, queries Stash for `organized: false` scenes. Simple, reliable.

## Current State

| Metric | Value |
|--------|-------|
| Total scenes | 749 |
| Organized | 609 (81%) — via TPDB |
| Unorganized | 140 (19%) |
| Vault size | 576 GB |
| Download pipeline | Prowlarr → Transmission → Vault |

### The Remaining 140 Unorganized

Breakdown after TPDB has done its work:

| Category | Count | Notes |
|----------|-------|-------|
| Erika Lust (main + series) | ~70 | Structured filenames with `.erikalust.com`. URL-only scraper — can't search. |
| Erika Lust extras (BTS/trailers) | ~20 | Should be categorized as extras, not scraped. |
| Ersties | ~18 | Informal titles. URL-only scraper. |
| yoursofia/moonkittenbbl (Chaturbate) | ~11 | Amateur content. No scraper exists. |
| realcollegegirls | 5 | Opaque OnlyFans PPV IDs. |
| SinDeluxe | 4 | NAME scraper might work but TPDB missed them. |
| Lustery (loose files) | 2 | Non-standard naming. |
| Misc (JAV, personal, one-offs) | ~10 | |

The LLM is best suited for these because the information is in the filename/folder, just not in a format any scraper can search.

### Existing Infrastructure (no changes needed)

- **FileMonitor plugin**: Watches `/media/Vault`, triggers scan on file changes
- **ThePornDB scraper**: FRAGMENT + NAME + URL (the current workhorse — matches ~80%)
- **ThePornDB for JAV**: Handles JAV codes (CAWD-910, etc.)
- **AI Tagger plugin**: Skier's AI models for visual tagging (not used by this tool, but available)
- **renamerOnUpdate plugin**: Renames files after metadata is applied
- **393 community scrapers**: Installed (207 NAME, 72 FRAGMENT, 574 URL-only)
- **StashDB box**: Configured with API key (~10-20% fingerprint match rate)
- **Stash GraphQL API**: Accessible at `localhost:9999/graphql` with API key

## Key Decisions

- **Two-stage only**: Stash Identify → LLM. We skip the "try every NAME scraper individually" layer because TPDB already covers most studios with NAME scrapers, and adding more would mostly duplicate work.
- **LLM extracts metadata, not URLs**: The LLM parses filenames directly into `{title, studio, performers, tags, date, language}` JSON. No URL discovery or HTML scraping.
- **Confidence gating**: LLM returns a confidence score. High confidence → auto-apply. Low confidence → tag `needs-review`.
- **No file renaming in this tool**: renamerOnUpdate plugin already handles renaming when metadata is applied.
- **Polling interval**: Daily via systemd timer.
- **Extras detection**: Files in `extras/` folders or with `Trailer`/`Behind The Scenes` in the name get tagged as "Trailer" or "Behind The Scenes" and marked organized without full metadata.

## Pipeline

```
FileMonitor detects new file
        │
        ▼
Stash auto-scan (adds scene with organized=false)
        │
        ▼
┌─── Organizer script (systemd timer, daily) ──────────┐
│                                                       │
│  1. Trigger metadataIdentify (StashDB + TPDB)         │
│     - Stash matches what it can via fingerprints      │
│       and TPDB NAME scraping                          │
│                                                       │
│  2. Query: findScenes(organized: false)               │
│                                                       │
│  3. For each remaining scene:                         │
│     a. Extras detection (folder/name heuristic)       │
│        ├─ Match → tag as Trailer/BTS, mark organized  │
│        └─ Not extra ↓                                 │
│     b. Send filename + folder to OpenRouter LLM       │
│        └─ Returns JSON: {title, studio, performers,   │
│           tags, date, confidence}                     │
│     c. Confidence gate:                               │
│        ├─ High → apply via sceneUpdate,               │
│        │          find/create studio & performers,    │
│        │          mark organized                      │
│        └─ Low  → tag "needs-review"                   │
│                                                       │
│  4. Log results (identified/llm-matched/reviewed)     │
└───────────────────────────────────────────────────────┘
```

## Stash GraphQL Operations Needed

- `metadataIdentify` — trigger Stash's built-in identify task
- `findScenes(scene_filter: {organized: false})` — get unorganized scenes
- `sceneUpdate` — apply metadata (title, studio, performers, tags, date)
- `tagFindByName` / `tagCreate` — find/create the "needs-review" and "Trailer" tags
- `findStudios` / `studioCreate` — find/create studios
- `findPerformers` / `performerCreate` — find/create performers

## OpenRouter Integration

- **API key**: Stored in sops (`openrouter-api-key` secret)
- **Model choice**: Start with a cheap/fast model (e.g. `google/gemini-2.0-flash-exp:free`, `anthropic/claude-haiku-4-5`, or `openai/gpt-4.1-mini`). Configurable via module option.
- **Prompt strategy**: System prompt instructs the model to extract metadata from the filename and return strict JSON with a confidence score. Few-shot examples for the common patterns (Erika Lust, Ersties, JAV, etc.).
- **Cost estimate**: 140 scenes × ~500 input tokens × cheap model = pennies for the initial backlog. Ongoing: a handful of scenes per day → negligible.

## Implementation as NixOS Module

- Python script, likely in `packages/vault-organizer/` (haumea auto-loads)
- Dependencies: `python3`, `requests` (GraphQL), standard lib for OpenRouter HTTP calls
- Secrets in sops:
  - `stash-api-key` (already conceptually exists)
  - `openrouter-api-key` (new)
- New constellation module: `modules/constellation/vault-organizer.nix`
  - Options: `enable`, `model`, `schedule`, `confidenceThreshold`
  - Systemd service + timer
  - Enabled only on `storage`

## Open Questions

- Should the initial backlog of 140 unorganized scenes be processed in one batch or throttled (e.g. 20 per run)?
- What confidence threshold for auto-apply? Starting guess: 0.8.
- Should we let the LLM see a list of existing performers/studios in Stash to encourage matching instead of creating duplicates?
- Should extras (trailers, BTS) be excluded from the Stash library entirely, or kept with an "extras" tag?

## Next Steps

→ `/ce:plan` for implementation details
