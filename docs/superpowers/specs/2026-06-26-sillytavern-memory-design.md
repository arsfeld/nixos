# SillyTavern memory system (basestar) — Design

**Date:** 2026-06-26
**Status:** Approved, applying directly on host
**Target host:** basestar (Docker container `chat`, image `ghcr.io/sillytavern/sillytavern`, ST 1.18.0)

## Goal

Give the single-user SillyTavern instance two complementary memory layers:

1. **Long-chat continuity** — a running summary of the story-so-far, auto-injected
   so the bot remembers events after they scroll out of the context window.
2. **Fact recall (RAG)** — semantic retrieval of relevant past messages and
   uploaded notes/lore (Data Bank), injected on demand.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Summary engine | Built-in **Summarize** extension (`extension_settings.memory`) | Already loaded; `source: "main"` reuses OpenRouter; no extra key/cost |
| Recall engine | Built-in **Vector Storage** extension (`extension_settings.vectors`) | Bundled; no third-party install |
| Embeddings source | **Local Transformers.js on basestar** (`source: "transformers"`) | No API key, no per-call cost, NSFW text never leaves the box |
| Embedding model | `Cohee/jina-embeddings-v2-base-en` | Already set in `config.yaml` (`extras.models.embedding`), auto-downloads from HF |
| Recall surfaces | Chat messages (`enabled_chats`) + files/Data Bank (`enabled_files`) | Covers "past events" and "uploaded notes/lore" |
| Backlog | Vectorize **new messages going forward**; "Vectorize All" per-chat is a manual, optional one-time step | Avoids running the local model over the whole backlog unattended |
| Delivery | Edit `default-user/settings.json` directly over SSH as root | Per user request; persists in the data volume (backed up nightly) |
| Nix changes | **None** | Engine (onnxruntime-node arm64), model, and both extensions already present |

## Why no Nix change is needed

Verified on the running container:

- `extension_settings.disabledExtensions == []` → both Summarize and Vector
  Storage are loaded. Summarize already runs at sane defaults (`source: "main"`,
  `memoryFrozen: false`, `promptInterval: 10`). Vector Storage is inert only
  because its settings are `{}`.
- `config.yaml` already sets `extras.models.embedding:
  Cohee/jina-embeddings-v2-base-en` with HuggingFace auto-download enabled.
- `onnxruntime-node` ships an `arm64/linux` binary in the image, so local
  embeddings actually run on basestar (aarch64).

## What changes (on disk, `default-user/settings.json`)

`extension_settings.vectors` is currently `{}`. Replace it with the extension's
own `defaultSettings` object (read from `public/scripts/extensions/vectors/index.js`
for this exact version) with these overrides:

- `source: "transformers"` (already the default — Local)
- `enabled_chats: true`
- `enabled_files: true`

Everything else stays at the version's defaults, notably:

- Chat recall: `template: "Past events:\n{{text}}"`, `position: 0` (IN_PROMPT),
  `depth: 2`, `protect: 5`, `insert: 3`, `query: 2`, `message_chunk_size: 400`,
  `score_threshold: 0.25`.
- Data Bank: `chunk_size_db: 2500`, `chunk_count_db: 5`,
  `file_template_db: "Related information:\n{{text}}"`, `file_position_db: 0`,
  `file_depth_db: 4`, `file_depth_role_db: 0` (SYSTEM).

`extension_settings.memory` (Summarize) is left at its existing sane defaults.

## Safe-apply procedure

`settings.json` is rewritten by the running app whenever the client saves, so
edit while the container is down to avoid a clobber:

1. Back up `default-user/settings.json` to a timestamped copy.
2. `docker stop chat`.
3. Edit `settings.json` with `node` from the image via
   `docker run --rm -v /var/data/sillytavern-data:/data …` (host has no
   node/python/jq): load JSON, set `extension_settings.vectors`, write back,
   re-parse to validate.
4. `docker start chat`.
5. Hard-refresh the browser at `https://chat.bat-boa.ts.net` so the client loads
   the new settings.

## Verification

1. JSON re-parses; `extension_settings.vectors.enabled_chats === true`.
2. Container healthy after start (`docker ps`, tsnsrv node `chat` up).
3. In a chat, send a message; confirm `default-user/vectors/` populates and the
   jina model downloads into the **mounted** data volume (persists across
   container recreation). If the model lands outside `/home/node/app/data`, add a
   volume mount in `hosts/basestar/services/sillytavern.nix` (only contingency
   that would touch Nix).
4. Confirm a `[Summary: …]` block appears in the prompt (Summarize) and a
   "Past events:" block once enough messages exist to retrieve (Vector Storage).

## Out of scope (YAGNI)

- Third-party memory extensions (qvink memory, MemoryBooks) — built-ins cover both goals.
- Hosted embeddings (OpenAI/Cohere) — rejected for privacy/cost.
- World Info / lorebook automation (`enabled_world_info`) — left off; can be enabled later.
- Declarative Nix management of `settings.json` — it is mutable UI state already covered by backups.
