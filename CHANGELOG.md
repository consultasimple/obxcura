## [Unreleased]

## [0.4.0] - 2026-08-18

Catches the client up with Obscura 0.2.0 — which grew a native render engine —
and gives extra headers and cookies proper read/write collections instead of raw
CDP calls. As always, every behaviour below was measured against the binary
rather than taken from the protocol docs, and the places where Obscura departs
from Chrome are documented instead of papered over: cookie reads that ignore the
URL you ask about, deletes that compare the path exactly, expired cookies that
linger in the jar, and a PDF engine that draws text rather than embedding it.

One breaking change, in `Page#cookies` — see below.

Also fixes a way to kill the browser outright from the public API.

### Changed

- **`Page#cookies` returns a collection, not an `Array`.** It used to hand back
  the connection's whole jar as an array of hashes; it now returns an
  `Obxcura::Cookies`, enumerable over the cookies the page's URL would actually
  send. `#map`, `#select`, `#find` and friends keep working, and the old value is
  `page.cookies.all`.

  What breaks quietly is integer indexing: `page.cookies[0]` used to be the first
  cookie hash and now looks up the cookie *named* `"0"`, so it returns `nil` —
  and `page.cookies[0]["value"]` becomes a `NoMethodError` on nil. Reach for
  `page.cookies.to_a[0]`, or better, `page.cookies["session"]`.

- CI pins Obscura `v0.2.0` and now installs the **render** build, since the
  screenshot specs would otherwise skip rather than fail. It also triggered on
  pushes to `master` while the default branch is `main`, so the push trigger
  could never fire; both are fixed.

### Added

- **`Page#cookies`** — the browser's cookie jar seen from one page: `Enumerable`
  over the cookies that page's URL would actually send, and writable. `#all`,
  `#[]`, `#for_url`, `#size`, `#empty?` for reading; `#set`, `#remove`, `#clear`
  for writing. Cookies stay raw CDP hashes with string keys, so what comes out of
  a read goes straight back into `#set` — `fresh.cookies.set(saved)` moves a
  logged-in session into another browser. Includes the `HttpOnly` cookies
  `document.cookie` cannot see, which is the whole reason to read them over CDP.

  `#set` takes `url:`, `domain:`, `path:`, `secure:`, `http_only:`, `same_site:`
  and `expires:` (a `Time` or epoch seconds), defaulting to the page's current
  URL because the browser refuses a cookie that belongs nowhere. Unknown options
  and a bad `same_site:` raise `ArgumentError` rather than reaching the browser,
  which accepts both silently — a bogus `sameSite` is stored as `Lax` without
  complaint.

  Four measured browser behaviours shaped this, all documented in
  [`docs/cookies.md`](docs/cookies.md):

  - **Cookie reads ignore the URL you ask about.** `Network.getCookies` accepts a
    `urls:` parameter and Obscura ignores it — that call, `Storage.getCookies`
    and `Network.getAllCookies` all return the whole connection-wide jar, from
    any page's session. So the scoping is done in Ruby, following RFC 6265
    §5.1.3–5.1.4: domain, path, `Secure`, expiry. Ports are not part of cookie
    scope.
  - **An expired cookie stays in the jar** and is simply never sent, so `#all`
    can show what will never go on the wire while the scoped view drops it.
  - **`Network.deleteCookies` compares the path exactly** — a delete aimed at
    `/cookies` leaves a cookie set on `/` alone, silently. `#remove` therefore
    looks the cookie up first and deletes at the domain and path the jar reports,
    and returns whether the jar actually changed.
  - **Host-only cookies cannot be told apart.** Chrome stores `Domain=example.com`
    as `.example.com`; Obscura stores it verbatim, leaving nothing to distinguish
    it from a host-only cookie. Domain matching is applied to every entry — over
    reporting beats losing the session cookie you came for.

- **`Page#headers`** — a small mutable collection for extra HTTP headers, in the
  shape Ferrum uses: `#get`/`#to_h`, `#set`, `#add`, `#clear`, plus `#[]`,
  `#[]=`, `#delete`, `#key?`, `#empty?` and `#size`. Names match
  case-insensitively per RFC 9110, so writing `x-token` after `X-Token` replaces
  it instead of sending both. Names and values are stringified, as CDP requires.

  `#get` reports what the object last sent, because that is the only readable
  record there is: CDP has no getter, and Obscura answers
  `Network.getExtraHTTPHeaders` with `Unknown Network method`.

  Two measured behaviours the documentation calls out rather than papering over.
  **The scope is the connection, not the page** — the API hangs off `Page`
  because that is the only session the command works from (sent without one it is
  accepted and silently does nothing), but Obscura keeps one table per
  connection, so two pages on a browser cannot carry different headers and the
  last write wins. And **they cover navigation only**: script-initiated requests
  never carry them, so `#post` still needs its own `headers` argument.

- **`Page#pdf`** — print the page, now that Obscura 0.2.0 can. Returns the raw
  PDF bytes, or writes them and returns the path with `path:`. Supports
  `landscape:`, `print_background:`, `scale:` (0.1..2.0), `page_ranges:`,
  `margin:` (one number or per side, in inches), and paper as either a name
  (`:letter`, `:legal`, `:tabloid`, `:a3`, `:a4`, `:a5`) or explicit
  `paper_width:`/`paper_height:` in inches.

  Verified against the binary by reading the generated PDFs, not by trusting
  byte sizes — an A4 render of the test page weighs *exactly* as much as the
  Letter one, so only the `/MediaBox` reveals that paper size applied at all
  (612x792pt vs 595x842pt). Landscape swaps the box, `scale:` changes the page
  count, and `page_ranges:` trims it.

  **Output is raster-backed.** Obscura reports `print-media-raster`, and a
  generated document has zero font objects and no extractable text — measured.
  It cannot be searched, selected, or read by a screen reader; use `#html` when
  you need the text. Header/footer rendering and CSS `@page` sizing are not
  implemented upstream, so those options are deliberately not exposed.

  Needs a build with the render feature, like `#screenshot`; the same refusal is
  mapped to an `Obxcura::Error` naming the asset to install. An unknown paper
  name, `paper:` combined with explicit dimensions, and a `scale:` outside
  0.1..2.0 all raise `ArgumentError` before any CDP round trip.

- **`Page#screenshot`** — real rasterisation, now that Obscura 0.2.0 ships a
  native render engine. Returns the raw image bytes (base64 is a CDP transport
  detail and is decoded here), or writes them and returns the path when given
  `path:`. Supports `:png` / `:jpeg` / `:webp`, `quality:` for `:jpeg`,
  `full_page:` for the whole document, and `clip:` for a region with optional
  `scale:`. Format is inferred from the `path:` extension when not given.

  Every option was verified against the 0.2.0 binary: `full_page:` really does
  capture past the viewport (1280x720 → 1280x2400 on the test page), `clip:` with
  `scale: 2` really doubles the raster, and `quality:` really changes the jpeg
  encode. Obscura's webp encoder is lossless and rejects `quality:` at any value,
  so that combination is refused client-side rather than round-tripped.

  Requires a build carrying the render feature. The `-no-render` archives of the
  same version refuse `Page.captureScreenshot`; that refusal surfaces as an
  `Obxcura::Error` naming the asset to install, not a bare `ProtocolError`.
  Unsupported formats and contradictory options (`full_page:` with `clip:`) raise
  `ArgumentError` before any CDP round trip.

### Fixed

- **`Browser#create_page(url)` no longer kills the browser.** Handing a URL to
  `Target.createTarget` works exactly once: the *second* such call on a
  connection takes `obscura serve` down outright — every command after it fails
  with `connection closed: end of file reached`, and the process is gone, not
  just the socket.

  ```ruby
  browser.create_page("https://www.google.com.mx")   # fine
  browser.create_page("https://example.com")         # browser dies here
  ```

  Measured on 0.2.0 and fully deterministic, whatever the URLs are — two local
  ones crash it just the same. One URL-loaded target is safe, any number of
  `about:blank` targets is safe, navigation is safe, and two URL-loaded targets
  on *separate* connections are safe. It is specifically the second
  `createTarget` carrying a URL.

  `#create_page` now always creates the target blank and navigates, so the
  parameter is honoured without handing callers a way to kill the browser. It
  blocks until the load event fires, which makes `#go_to` simply its expressive
  name. The workaround note on `#go_to` was also slightly wrong: the crash needs
  no `evaluate`, it lands on the `create_page` call itself.

## [0.3.0] - 2026-07-29

Realigns the client with Obscura 0.1.11, which lifted several of the browser
limits this gem was built around. Every change below was verified against the
0.1.11 binary rather than taken from the release notes — two claims in those
notes did not hold, and are documented as still-standing constraints.

### Changed

- **Breaking:** `Page#xhr_post` is now `Page#post` and uses `fetch`, which
  Obscura routes as of 0.1.11. `xhr_post` remains as a deprecated alias.
  `timeout:` is now enforced *in the page* by racing the request against a
  timer, so a tarpitting server fails at roughly `timeout:` instead of waiting
  out the CDP reply timeout. It races rather than using `AbortSignal.timeout`
  because an abort's rejection is swallowed and surfaces as `undefined`.
- **Breaking:** `Node#type` dispatches real key events via
  `Input.dispatchKeyEvent` instead of assigning `value` directly, so the browser
  performs the insertion and `keydown`/`input`/`keyup` fire as they would from a
  keyboard. `change` no longer fires per keystroke — real browsers only fire it
  on blur, so listeners depending on the old behaviour should use `input`.
  `Input.insertText` is still unimplemented, so insertion is per character.
- **Breaking:** `Frame#read_string` and `Runtime::EVALUATE_CHUNK` are removed,
  along with the `window.__obxcura_read` global. Obscura's single-message ceiling
  went from ~500–700 KB to 64 MiB, so `Page#html` reads `outerHTML` in one round
  trip. Verified with 8 MiB and 16 MiB strings.
- `Node#submit` always uses `requestSubmit` and no longer falls back to
  `submit()`. In 0.1.11 the two genuinely differ — `submit()` bypasses the
  cancelable submit event — so the fallback would have quietly skipped both
  constraint validation and any registered listener.

### Added

- `Page#network_log` — the request log has existed as internal state since
  0.1.0, but `Network.enable` was never sent, so no events ever arrived and
  nothing could read it. The domain is now enabled per page and the log is
  exposed. Scope is navigation-driven requests only: script-initiated requests
  emit no CDP network events, so `#post` traffic does not appear. This
  contradicts the 0.1.11 note for #415, and was confirmed by measurement.
- `Browser#clear_cookies` — listed in the 0.1.0 changelog and referenced in the
  docs, but never actually implemented; the call site was commented out in
  `Page#close`. Now a real method. Note cookies no longer leak between
  connections in 0.1.11, so this only resets state within one connection.

### Performance

- `Client::READ_CHUNK` raised from 512 B to 64 KiB. With frames now reaching
  64 MiB, a 512-byte read turned a single reply into tens of thousands of
  syscalls. Measured on a 16 MiB reply: 0.188s → 0.105s. Past 64 KiB the curve
  flattens.

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
