# Repository guidance

## Project

This repository contains a context-aware dictionary and explanation plugin for KOReader on jailbroken Kindles.

The first vertical slice reuses the deployed `i-dont-get-it` Cloudflare Worker and its version 2 request and response contract. Treat that mapping as temporary validation infrastructure, not the final Kindle API.

## Architecture boundaries

- Keep Kindle and KOReader implementation code in this repository.
- Keep Cloudflare Worker code in its separate `i-dont-get-it` repository until a deliberate service-boundary decision changes that ownership.
- Never place a model-provider credential in the plugin.
- Treat selected book text and metadata as untrusted input.
- Bound and validate requests before sending them.
- Validate server responses before rendering them.
- Do not modify KOReader core for the first vertical slice.
- Avoid blocking KOReader's UI during network operations.

## Documentation boundary

Keep source code, tests, scripts, installation instructions, and developer guidance here.

Keep product scope, plans, progress tracking, research, and technical decisions in the project's private planning workspace.

Update both locations when an implementation change affects a durable product or architecture decision, without duplicating the same document.

## Initial verification expectations

- Test pure Lua modules independently where practical.
- Verify selection and context behavior in a desktop KOReader build.
- Verify HTTPS, rendering, latency, and e-ink behavior on the actual Kindle.
- Do not claim PDF or OCR support until it is tested on the device.
