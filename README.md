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

Obscura routes `XMLHttpRequest` but not `fetch`, so `#xhr_post` runs the POST
from the page's context (reusing its cookies). Values cross as arguments:

```ruby
result = page.xhr_post(
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
to bound it. Some anti-bot endpoints tarpit non-stealth clients — try
`obscura serve --stealth`.

## API

`Obxcura.start(**opts)` is sugar for `Obxcura::Browser.new`.

- **`Obxcura::Browser`** — `.new(host:, port:, timeout:)`, `#create_page(url)`,
  `#go_to`/`#goto`, `#targets`, `#version`, `#command`, `#close`/`#quit`.
  Readers: `#client`, `#pages`, `#host`, `#port`.
- **`Obxcura::Page`** — `#goto`/`#go_to`, `#evaluate`, `#evaluate_func`,
  `#html`/`#body`, `#title`, `#current_url`, `#at_css`, `#css`, `#xhr_post`,
  `#cookies`, `#refresh`/`#reload`, `#command`, `#close`, `#close_connection`.
  Readers: `#frame`, `#target_id`, `#session_id`, `#client`.
- **`Obxcura::Node`** (from `#at_css`/`#css`) — `#text`, `#[]` (attribute),
  `#outer_html`, `#object_id`.
- **`Obxcura::Frame`** — the main frame behind a Page; carries the DOM/Runtime
  methods Page delegates (`#evaluate`, `#at_css`, `#read_string`, …).
- **`Obxcura::Client`** — the CDP transport, if you need raw `#command`,
  `#subscribe` / `#unsubscribe`, or `#close`.

Errors all descend from `Obxcura::Error`: `TimeoutError`, `ProtocolError`,
`ConnectionError`.

## Obscura's quirks (and how Obxcura handles them)

These are properties of the **Obscura browser**, not of this gem. They shape the
API, so they're worth knowing:

- **No paint engine.** There is no screenshot API, and there never will be one
  here. `Page.captureScreenshot` is unusable.
- **~500–700 KB message ceiling.** Obscura won't send a single CDP message
  larger than that. `Page#html` works around it by snapshotting `outerHTML` into
  a page global and pulling it back in 400 KB slices. Don't return giant values
  from `#evaluate` directly.
- **DOM nodes don't serialize.** A node returned by value comes back as an
  internal stub, so `#at_css` / `#css` resolve it (via `DOM.resolveNode`) to a
  live handle and read it with `Runtime.callFunctionOn`.
- **XHR, not fetch.** Obscura routes `XMLHttpRequest` but not `fetch`, so
  `#xhr_post` uses XHR from the page context. It also ignores
  `XMLHttpRequest#timeout`, so the effective bound is the CDP-level `timeout:`.
- **Persistent cookies.** `obscura serve` is long-lived and its cookie jar
  survives `#quit` (that only drops the WebSocket). Read them with
  `page.cookies`; closing a page clears the browser's cookie jar.
- **Private networks are blocked by default.** To drive a local site, start the
  browser with `obscura serve --allow-private-network`.

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
