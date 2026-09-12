# Third-party notices

## UI framework and editor

- GPUI 0.2.2: Zed Industries and contributors. Apache-2.0.
  Source: https://github.com/zed-industries/zed/tree/main/crates/gpui
  License: `third-party/GPUI-APACHE-2.0.txt`.
- GPUI Component 0.5.1 and GPUI Component Assets 0.5.1: Longbridge and contributors. Apache-2.0.
  Source: https://github.com/longbridge/gpui-component
  The unmodified crates provide the multiline editor, selection, history, search,
  Tree-sitter integration, theme and UI icons. Versions are pinned in Cargo.lock.
  The Apache-2.0 license text is bundled in `third-party/GPUI-APACHE-2.0.txt`.
- Bundled SVG icons originate from Lucide, including Feather-derived icons.
  Source and licensing: https://lucide.dev/license
  ISC and MIT notices: `third-party/LUCIDE-LICENSE.txt`.

The former GPUI example-based single-line input (`src/input.rs`) was removed in 0.2.
No GPL-licensed Zed editor/language/text/multi_buffer source is included.

## Syntax grammars and transitive dependencies

`docs/dependency-inventory.tsv` records the 582 resolved dependencies (including
build and test tools) for `aarch64-apple-darwin` and the selected features on 2026-09-08.
Tree-sitter grammar versions and declared licenses are included in this inventory.
`tree-sitter-graphql 0.1.0` uses `license-file` instead of an SPDX field; its bundled
MIT license is copied to `third-party/TREE-SITTER-GRAPHQL-MIT.txt`.
The two MPL-2.0 dependencies are `cbindgen 0.28.0` and `option-ext 0.2.0`.

## Distribution status

This is a local development prototype, not a signed and notarized commercial release.
The packaging script includes this notice and `third-party/` license texts in the app.
This is not yet the complete redistributable notices/source-offer bundle for every
transitive dependency. Review the exact target/features, grammar/query sources,
icons, native libraries and other final assets before commercial distribution.

The original Readit source has not been assigned an open-source license.


## Local language servers (0.3)

Readit implements its own LSP client; it does not embed Zed's language engine.
Language servers run as local processes on demand. npm versions are pinned in
`tools/lsp/package-lock.json`:

- Pyright 1.1.413, Microsoft Corporation: MIT. `third-party/PYRIGHT-MIT.txt`.
  https://github.com/microsoft/pyright
  Bundled typeshed: `third-party/PYRIGHT-TYPESHED-LICENSE.txt`.
- TypeScript Language Server 6.0.0, TypeFox and contributors: Apache-2.0.
  `third-party/TYPESCRIPT-LANGUAGE-SERVER-LICENSE.txt`.
  https://github.com/typescript-language-server/typescript-language-server
- TypeScript 5.9.3, Microsoft Corporation: Apache-2.0.
  `third-party/TYPESCRIPT-APACHE-2.0.txt` and `third-party/TYPESCRIPT-THIRD-PARTY-NOTICES.txt`.
  https://github.com/microsoft/TypeScript
- rust-analyzer: MIT OR Apache-2.0, invoked from the locally installed Rust toolchain.
  https://github.com/rust-lang/rust-analyzer

These direct notices do not replace the complete distribution review of bundled
server dependencies, Node.js, Rust toolchain components, and final application assets.
The current development app refers to the repository's local server directory.

## Local GPUI Component patch

`vendor/gpui-component` contains gpui-component 0.5.1 under Apache-2.0.
Readit exposes layout and selection methods for pointer navigation and MCP control.
See `vendor/gpui-component/READIT-PATCH.md` and `LICENSE-APACHE`.
