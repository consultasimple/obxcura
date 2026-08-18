# Pages

A `Page` is one CDP target with its own attached session. You get one from a
`Browser`, never by calling `Page.new` yourself.

```ruby
page = browser.create_page                        # about:blank
page = browser.create_page("https://example.com") # create + navigate + wait
page = browser.go_to("https://example.com")       # the same thing, named better
```

## `Browser#create_page(url = "about:blank")`

Creates a target, attaches to it, and — when given a URL — navigates there and
blocks until the load event fires. Returns the tracked `Page`.

The target is **always created blank and then navigated**, never opened at the
URL directly. Handing a URL to `Target.createTarget` works exactly once: the
second such call on a connection kills `obscura serve`, process and all. See
[Browser constraints](constraints.md). The parameter is honoured by navigating
instead, so this is not something you can trip over through the gem.

## `Browser#go_to(url)` / `#goto`

The expressive name for `#create_page` with a URL — identical behaviour. Returns
the `Page`, already loaded.

## `Page#goto(url)` / `#go_to`

Navigate an existing page and block until its `load` event fires. Returns `self`,
so it chains.

```ruby
page.goto("https://example.com").title
```

The wait is bounded by the client timeout (30s by default) and raises
`Obxcura::TimeoutError` — `"Page load timed out"` — if the event never arrives.

**Loading is not the same as settled.** Obscura pumps the page event loop for a
short window after `load` — roughly 400–500ms — and then stops. Timers scheduled
beyond that never fire. Do not write `goto` + `sleep 3` and expect background
JavaScript to have advanced; it has not. See [Browser
constraints](constraints.md).

## `Page#refresh` / `#reload`

Reloads and waits for `load` again.

```ruby
page.reload
```

## `Page#close`

Closes the target and stops listening for its events. The browser forgets the
page, and so does `browser.pages`.

```ruby
page.close
```

Safe to call twice: a target that is already gone raises `ProtocolError`
internally and is swallowed.

## `Page#close_connection`

Drops the underlying WebSocket. This affects the **whole browser**, not just this
page — every other page on that connection dies with it. Reach for it when a
command is wedged and you want out without waiting.

```ruby
page.close_connection
```

## Identity and internals

```ruby
page.target_id     # => "target-1"    the CDP target
page.session_id    # => "session-2"   the attached session
page.client        # => Obxcura::Client, shared with the whole browser
page.frame         # => Obxcura::Frame, the main frame
```

`Page` delegates its content and scripting methods to that frame — `#evaluate`,
`#evaluate_func`, `#current_url`, `#title`, `#html`, `#body`, `#at_css`, `#css`.
They are documented in [Reading content](content.md), [Querying the
DOM](dom.md) and [Running JavaScript](javascript.md).

## `Page#command(method, params = {})`

Send any CDP command scoped to this page's session. This is the escape hatch for
anything the gem does not wrap.

```ruby
page.command("Emulation.setDeviceMetricsOverride",
  width: 375, height: 812, deviceScaleFactor: 3, mobile: true)

page.command("Page.captureScreenshot", format: "png")["data"]   # raw base64
```

It returns the CDP `result` object and raises `Obxcura::ProtocolError` when the
browser reports an error — which is how you find out an option is unimplemented:

```ruby
page.command("Page.printToPDF", displayHeaderFooter: true)
# => Obxcura::ProtocolError: Page.printToPDF does not yet support headers and footers
```
