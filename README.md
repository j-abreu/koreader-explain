# KOReader Explain

KOReader Explain is a context-aware explanation plugin for jailbroken Kindles running [KOReader](https://koreader.rocks/). Select text in a book and choose **Explain in context** to get a concise explanation grounded in the current passage and, when needed, earlier passages from the same book.

The plugin is intended for EPUB and other reflowable books backed by KOReader's CREngine. It uses the shared Context Explain API for model inference; it does not contain provider credentials.

## What it does

- Adds **Explain in context** to the selection menu and dictionary popup.
- Captures the selection, nearby reading context, and available book, chapter, and language metadata.
- Explains clear selections immediately. When context is insufficient, requests a small, model-directed local search plan and completes the explanation using only the selected local excerpts.
- Searches earlier content by default for narrative books. Whole-book search is offered only with explicit reader approval for reference-style material.
- Excludes detectable front matter from retrieval and keeps search results bounded: up to three queries, 50 inspected candidates per query, three excerpts per query, and six excerpts overall.
- Shows related terms for ordinary lowercase single-word concepts when useful general synonyms exist. It omits them for names, phrases, passages, situations, and book-specific terms.
- Provides **Inspect context**, **Probe local search**, and **Inspect last retrieval** to make requests and local retrieval behavior inspectable on-device.

Position-aware local retrieval requires CREngine search and XPointer APIs. PDFs and other unsupported document types still provide bounded context, but cannot supply local evidence when an explanation requires retrieval.

## Privacy and safety

Selected text, context, and local excerpts are treated as untrusted input. The plugin bounds every request and validates every server response before showing it. No model-provider credential is stored on the Kindle.

Local search runs on the device. Only the small excerpts chosen by the bounded search policy are sent to the explanation service for a completion request.

## Installation

1. Install KOReader on a jailbroken Kindle and ensure the device can reach the Context Explain API.
2. Copy `idontgetit.koplugin/` into KOReader's `plugins/` directory. Back up an existing installation first.
3. Restart KOReader.
4. In a supported book, select text and choose **Explain in context**.

On a Kindle, the target directory is normally `/mnt/us/koreader/plugins/idontgetit.koplugin/`.

## Development

The plugin is Lua; it has no compilation step. Use KOReader's LuaJIT runtime for the closest verification.

```sh
luajit tests/run.lua .
```

On a Kindle, syntax-check changed modules and run the focused tests against the installed plugin path:

```sh
/mnt/us/koreader/luajit -e 'assert(loadstring(io.stdin:read("*a")))' < idontgetit.koplugin/main.lua
/mnt/us/koreader/luajit tests/run.lua /mnt/us/koreader/plugins
```

For device testing, copy the changed plugin files into the installed directory and restart KOReader so it reloads Lua modules.

## Repository layout

```text
idontgetit.koplugin/
├── main.lua                 # menus, lifecycle, and request orchestration
├── context.lua              # bounded selection and context capture
├── contract_v4.lua          # v4 API request and response validation
├── book_search.lua          # bounded on-device retrieval
├── retrieval_audit.lua      # reader-visible retrieval audit
├── api_client.lua           # cancellable HTTPS transport
└── explanation_viewer.lua   # native KOReader explanation UI
tests/run.lua                # focused Lua test harness
```

## Related projects

The Cloudflare Worker, versioned API contracts, prompts, and deployment workflow live in the sibling `context-explain-api` repository. This repository owns the Kindle and KOReader implementation.
