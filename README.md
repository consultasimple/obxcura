# Obxcura

A small Ruby client for the [Obscura](https://github.com/h4ckf0r0day/obscura)
headless browser, driven over the Chrome DevTools Protocol.

A `Browser` owns one WebSocket connection; each `Page` is a CDP target with its
own attached session. One connection, many pages.

> **Obxcura vs Obscura.** This gem is `Obxcura`. The browser it drives is
> `obscura` — a separate binary you run yourself. The `x` keeps them apart.

## Installation

```bash
bundle add obxcura
```

You also need the `obscura` binary on your `PATH`
([releases](https://github.com/h4ckf0r0day/obscura/releases)).

## Usage

Start the browser first (defaults to port 9222):

```bash
obscura serve
```

Then:

```ruby
require "obxcura"

browser = Obxcura::Browser.new     # or Obxcura.start
page    = browser.go_to("https://example.com")

page.html                          # rendered DOM, post-JS
page.title                         # "Example Domain"
page.current_url                   # "https://example.com/"
page.evaluate("1 + 2")             # => 3

browser.quit
```

### Querying the DOM

`#at_css` / `#css` return live `Obxcura::Node` handles backed by the real DOM:

```ruby
page.at_css("h1").text             # => "Example Domain"
page.at_css("a")["href"]           # attribute value, or nil
page.at_css("h1").outer_html       # "<h1>Example Domain</h1>"
page.css("p").map(&:text)          # every <p>'s text
page.at_css("#missing")            # => nil
```

### Running JavaScript

Pass Ruby values as arguments — they cross into the page as real values
(`arguments[0]`, `arguments[1]`, …), never string-interpolated into source:

```ruby
page.evaluate("arguments[0] * 2", 21)          # => 42

# `evaluate_func` calls a function declaration directly:
page.evaluate_func(<<~JS, "h1")
  function(sel) { return document.querySelector(sel).textContent; }
JS
```

### POSTing from inside the page

`#post` runs the POST from the page's context with `fetch`, reusing its cookies.
Values cross as arguments:

```ruby
result = page.post(
  "https://example.com/api/login",
  URI.encode_www_form(user: "me", pass: "secret"),   # payload
  "application/x-www-form-urlencoded",                # content type
  { "X-Requested-With" => "XMLHttpRequest" }          # headers
)

result["status"]   # => 200
result["ok"]       # => true  (2xx)
result["body"]     # response text
```

Any HTTP reply (including 4xx/5xx) comes back as `{ "status", "ok", "body" }`.
A transport failure — the request never reached the server (CORS, the
private-network SSRF guard, mixed origin, a dead host) — raises
`Obxcura::ConnectionError`. If the server accepts the connection but never
answers, the wait ends with `Obxcura::TimeoutError`; pass `timeout:` (seconds)
to bound it, and the request is dropped in the page at roughly that mark. Some
anti-bot endpoints tarpit non-stealth clients — try `obscura serve --stealth`.

> Before Obscura 0.1.11 this had to use `XMLHttpRequest`, because `fetch` wasn't
> routed. The old name `#xhr_post` still works as a deprecated alias.

### Screenshots

```ruby
page.screenshot                                  # => raw PNG bytes
page.screenshot(path: "shot.png")                # writes the file, returns the path
page.screenshot(path: "shot.jpg", quality: 80)   # format inferred from the extension
page.screenshot(full_page: true)                 # whole document, not just the viewport
page.screenshot(clip: { x: 0, y: 0, width: 300, height: 200, scale: 2 })
```

Formats are `:png` (default), `:jpeg` and `:webp`. `quality:` is 0–100 and applies
to **`:jpeg` only** — `:png` ignores it, and Obscura's webp encoder is lossless and
refuses the parameter at any value. Without `path:` you get the image bytes back —
base64 is a CDP transport detail and is decoded for you.

> Requires Obscura 0.2.0 or newer, **and** a build with the render feature. The
> `-no-render` release archives refuse to rasterise, and `#screenshot` reports
> that as an `Obxcura::Error` rather than a raw protocol failure.

## API

`Obxcura.start(**opts)` is sugar for `Obxcura::Browser.new`.

- **`Obxcura::Browser`** — `.new(host:, port:, timeout:)`, `#create_page(url)`,
  `#go_to`/`#goto`, `#targets`, `#version`, `#clear_cookies`, `#command`,
  `#close`/`#quit`. Readers: `#client`, `#pages`, `#host`, `#port`.
- **`Obxcura::Page`** — `#goto`/`#go_to`, `#evaluate`, `#evaluate_func`,
  `#html`/`#body`, `#title`, `#current_url`, `#at_css`, `#css`, `#post`,
  `#screenshot`, `#cookies`, `#network_log`, `#refresh`/`#reload`, `#command`,
  `#close`, `#close_connection`. Readers: `#frame`, `#target_id`, `#session_id`,
  `#client`.
- **`Obxcura::Node`** (from `#at_css`/`#css`) — `#text`, `#value`, `#[]`
  (attribute), `#at_css`, `#focus`, `#type`, `#submit`, `#outer_html`.
- **`Obxcura::Frame`** — the main frame behind a Page; carries the DOM/Runtime
  methods Page delegates (`#evaluate`, `#at_css`, `#call_on`, …).
- **`Obxcura::Client`** — the CDP transport, if you need raw `#command`,
  `#subscribe` / `#unsubscribe`, or `#close`.

Errors all descend from `Obxcura::Error`: `TimeoutError`, `ProtocolError`,
`ConnectionError`.

## Obscura's quirks (and how Obxcura handles them)

These are properties of the **Obscura browser**, not of this gem. They shape the
API, so they're worth knowing:

- **Screenshots need a render build.** Obscura gained a paint engine in 0.2.0,
  but the `-no-render` release archives of the *same version* omit it and refuse
  `Page.captureScreenshot`. `#screenshot` turns that refusal into an
  `Obxcura::Error` telling you which asset to install. (Before 0.2.0 there was no
  paint engine at all, and this gem deliberately had no screenshot API.)
- **DOM nodes don't serialize.** A node returned by value comes back as an
  internal stub, so `#at_css` / `#css` resolve it (via `DOM.resolveNode`) to a
  live handle and read it with `Runtime.callFunctionOn`.
- **In-page throws vanish.** A JS `throw` comes back as `undefined` rather than
  an exception, so the gem returns `{ error: ... }` sentinels and raises from
  Ruby. It's also why `#post` bounds itself by racing a timer instead of using
  `AbortSignal.timeout` — the abort works, but its rejection doesn't survive the
  trip, so the reason has to come back as a resolved value.
- **The network log only sees navigation.** `#network_log` records the document
  and its subresources. Script-initiated requests — including `#post` — emit no
  CDP network events at all, so they never appear.
- **No bulk text insertion.** `Input.insertText` isn't implemented, so `#type`
  dispatches one key event per character via `Input.dispatchKeyEvent`. Real
  `keydown`/`input`/`keyup` fire; `change` does not, matching browsers, which
  only fire it on blur.
- **Private networks are blocked by default.** To drive a local site, start the
  browser with `obscura serve --allow-private-network`.

Two long-standing limits were lifted in Obscura 0.1.11, so if you've read older
notes: the **~500–700 KB message ceiling is gone** (64 MiB now, so `#html`
returns even a huge document in one round trip), and **cookies no longer leak
between connections** — each `Browser` gets its own browser context, and
`#clear_cookies` is now only about resetting state within one connection.

The transport is built directly on `websocket-driver` rather than
`websocket-client-simple`, which reads a byte at a time and wedges on large
frames.

## Development

```bash
bin/setup
bundle exec rake          # rubocop + rspec
bundle exec rake doc      # YARD docs into doc/
bin/console               # IRB with the gem loaded
```

The integration specs boot a real `obscura serve` against a local WEBrick test
site. Point them at your binary:

```bash
OBSCURA_BIN=/path/to/obscura bundle exec rspec
```

Without the binary those specs skip cleanly, so `bundle exec rspec` still passes.

## Contributing

Bug reports and pull requests are welcome at https://github.com/memoxmrdl/obxcura.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
