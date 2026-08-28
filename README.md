# KOReader Explain

A context-aware dictionary and explanation plugin for jailbroken Kindles running KOReader.

The first vertical slice captures selected text and bounded ebook context, calls the shared Context Explain API's book endpoint, and displays its structured explanation in a native KOReader interface.

## Status

The first live device slice is scaffolded. It adds **Explain in context** to KOReader's selection menu and **Explain** to the native dictionary popup, captures bounded ebook context plus available book and chapter metadata, calls the source-bound version 2 Context Explain API in a background subprocess, validates its response, and displays the structured explanation in a native viewer.

The explanation viewer provides **Retry** to resubmit the exact captured snapshot and **Close** to return to the book. **Inspect context** is a local-only action that shows the exact version 2 JSON request body, including any earlier mentions, without calling the API.

The initial context window captures up to 50 words on each side of the selection. The nearest 450 Unicode characters from each side are retained so the request remains within the API's field limits. For one- to three-word selections in CREngine-backed reflowable books (such as EPUB), it also searches locally for up to five earlier occurrences and sends a 280-character excerpt for each match. PDF and other unsupported formats continue with immediate context only.

## Source layout

```text
idontgetit.koplugin/
├── _meta.lua
├── main.lua
├── context.lua
├── contract.lua
├── api_client.lua
└── explanation_viewer.lua
```

## Documentation

Implementation, installation, and contributor guidance live in this repository. Product-planning notes are maintained separately.
