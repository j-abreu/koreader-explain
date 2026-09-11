# KOReader Explain

A context-aware explanation plugin for jailbroken Kindles running KOReader. It adds **Explain in context** to selection and dictionary menus and renders the result in a native KOReader viewer.

## Current state

Feature 04 is implemented and validated on a Kindle with CREngine-backed EPUBs.

- The plugin captures a bounded selection, sentence-aware local context, and book metadata.
- It calls the Context Explain API's v4 book route. The model either answers directly or returns a bounded plan of one to three local searches.
- Local search runs only after that plan. Narrative books search before the selection; whole-book search requires explicit reader approval and is limited to reference-style books.
- Results are bounded (50 inspected candidates per query, three excerpts per query, six total) and exclude TOC-detectable front matter.
- A single completion request uses the captured excerpts to produce the final spoiler-safe explanation.
- **Inspect context**, **Probe local search**, and **Inspect last retrieval** make request and retrieval behavior auditable from KOReader.
- Related terms appear only for a lowercase, single-word ordinary concept when useful general synonyms exist. They are suppressed for phrases, passages, situations, proper names, and book-specific terms.

CREngine position and search APIs are required for local retrieval. Unsupported document types retain the safe context-only explanation path.

## Layout

```text
idontgetit.koplugin/
├── main.lua                 # KOReader menus and v4 request lifecycle
├── context.lua              # bounded selection and context capture
├── contract_v4.lua          # v4 request/response boundary
├── book_search.lua          # bounded local retrieval
├── retrieval_audit.lua      # reader-visible retrieval audit
├── api_client.lua           # cancellable HTTPS transport
└── explanation_viewer.lua   # native explanation UI
tests/run.lua                # focused Lua checks
```

## Build and verify

The plugin is Lua; there is no compilation step. Use KOReader's bundled LuaJIT where possible.

```sh
luajit tests/run.lua .
```

On a Kindle, syntax-check changed modules and run the same tests with the device runtime:

```sh
/mnt/us/koreader/luajit -e 'assert(loadstring(io.stdin:read("*a")))' < idontgetit.koplugin/main.lua
/mnt/us/koreader/luajit tests/run.lua /mnt/us/koreader/plugins
```

To install for device testing, copy `idontgetit.koplugin/` into KOReader's `plugins/` directory, preserving a backup of the installed plugin first, then restart KOReader. The API is deployed separately from the sibling `context-explain-api` repository.

## Documentation

This repository contains plugin implementation, tests, and installation guidance. Product plans and tracker notes live in the private planning workspace.
