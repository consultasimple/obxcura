## [Unreleased]

## [0.2.0] - 2026-07-20

### Added

- `Node` form actions: `value`/`attribute`, `at_css` (scoped `querySelector`),
  `focus`, `type` (sets value and fires `input`/`change`, since Obscura has no
  Input domain), and `submit` (raising `ProtocolError` for a node with no form).
- `Frame#to_node` is now public so `Node#at_css` reuses the same node
  resolution.

## [0.1.1] - 2026-07-14

### Fixed

- Corrected gemspec repository URLs (`homepage`, `source_code_uri`,
  `changelog_uri`) to point at the actual GitHub repository.

## [0.1.0] - 2026-07-09

Initial release. A Ruby client that drives the Obscura headless browser over
the Chrome DevTools Protocol.

### Added

- `Browser` — target lifecycle over a single WebSocket, cookie management
  (`cookies`, `clear_cookies`), and `quit`.
- `Page` — navigation with load waiting, `evaluate`, DOM access, form filling,
  JSON/form XHR POSTs, and network logging. Each page is a CDP target with its
  own attached session, multiplexed over the shared socket.
- `Client` — WebSocket transport built directly on `websocket-driver`, with a
  single reader thread routing command replies by `id` and events by
  `sessionId`.
- `Frame` (with `Runtime` and `DOM` mixins) and `Node` helpers for scripting
  and DOM queries.
- Chunked reads (`read_string`) so large-string getters like `Page#html`
  work around Obscura's ~500–700 KB single-message ceiling.
- Optional `nokogiri` integration in `Page#dom`, lazily required.
- Integration test suite that boots one `obscura serve` plus a local WEBrick
  site, tagged `:obscura` and skipped when no browser binary is available.
