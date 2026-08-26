# kindle-ai-dictionary

A context-aware dictionary and explanation plugin for jailbroken Kindles running KOReader.

The first vertical slice will capture selected text and bounded ebook context, call the existing `i-dont-get-it` Cloudflare Worker, and display its structured explanation in a native KOReader interface.

## Status

The first live device slice is scaffolded. It adds **Explain in context** to KOReader's selection menu and **Explain** to the native dictionary popup, captures bounded ebook context plus available book and chapter metadata, calls the existing Cloudflare Worker in a background subprocess, validates its version 2 response, and displays the structured explanation in a native viewer.

The explanation viewer provides **Retry** to resubmit the exact captured snapshot and **Close** to return to the book.

The initial context window captures up to 50 words on each side of the selection. The nearest 450 Unicode characters from each side are retained so the request remains within the current Worker's version 2 field limits.

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
