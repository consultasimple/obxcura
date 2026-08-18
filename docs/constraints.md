# Browser constraints

These are properties of the **Obscura browser**, not of this gem. They shape the
API, and several of them look like bugs in your code until you know about them.
All of it measured against real binaries.

## Background JavaScript stops early

Obscura pumps the page event loop for a bounded window after `load` — roughly
400–500ms — and then stops. Timers scheduled past that never fire.

```ruby
page.evaluate("setTimeout(() => { window.done = true }, 2000)")
sleep 3
page.evaluate("window.done")    # => nil
```

**Do not write `goto` + `sleep` and expect the page to have progressed.** It has
not. Read what is there, drive the page with real input, or do the work inside a
single `#evaluate` — promises awaited within one call resolve properly.

## An unsettled promise starves the whole connection

A `Runtime.evaluate` with `awaitPromise` whose promise never settles blocks
**every** command on that socket — other pages and browser-level commands alike —
until the browser abandons it.

The client-side `timeout:` only stops the Ruby wait. The browser keeps holding
the connection.

| | 0.1.11 | 0.2.0 |
|---|---|---|
| Connection recovers after | ~4s | **~30s** |

Not new in 0.2.0 — the cap simply grew from four seconds, which hid in the noise,
to thirty, which does not. The blast radius is the **connection**, not the
session: a separate `Browser` stays responsive throughout.

Practical consequences:

- Never leave a promise pending.
- If a command is wedged and you want out, drop the socket
  (`browser.client.close`) rather than `#quit`, which sends `Target.closeTarget`
  over that same starved connection and waits behind it.

## A second target created at a URL kills the process

`Target.createTarget` accepts a URL and honours it — once. The **second** call
carrying a URL on the same connection takes `obscura serve` down: the command
fails with `connection closed: end of file reached`, and the process itself is
gone, not just the socket.

| | process |
|---|---|
| one target created at a URL | survives |
| any number of `about:blank` targets | survives |
| creating blank, then navigating (any number of times) | survives |
| two URL-created targets on *separate* connections | survives |
| **two URL-created targets on one connection** | **dies** |

Deterministic on 0.2.0, and nothing to do with the sites — two localhost URLs
kill it exactly the same way.

[`#create_page`](pages.md) therefore always creates the target blank and then
navigates, whether or not you passed a URL, so this is not reachable through the
gem. It matters if you drive `Target.createTarget` yourself through
[`#command`](pages.md).

## In-page throws vanish

A JavaScript `throw` comes back as `undefined`, not an exception. Return
`{ error: ... }` sentinels and raise from Ruby. See
[Running JavaScript](javascript.md) and [Errors](errors.md).

This is also why [`#post`](http.md) bounds itself with `Promise.race` against a
timer instead of `AbortSignal.timeout`: the signal is accepted, but when the abort
fires the rejection is swallowed and the call returns `undefined`, so the reason
has to arrive as a *resolved* value.

## Network events only cover navigation

`Network.enable` works, and the document plus its subresources emit
`requestWillBeSent` / `responseReceived` / `loadingFinished`. Script-initiated
requests emit **nothing**. So `#post` traffic never lands in
[`#network_log`](http.md) — measured, despite upstream notes claiming otherwise.

## `Input.insertText` is unimplemented

There is no bulk-insert path, so [`#type`](forms.md) dispatches per character at
two round trips each. `Input.dispatchKeyEvent` *is* implemented, which is why
real key events fire.

## DOM nodes do not serialize

A node returned by value comes back as an internal stub carrying an `_nid`. The
gem resolves it through `DOM.resolveNode` into a live handle. Cost: an extra
round trip per node, and handles go stale across navigation. See
[Querying the DOM](dom.md).

## Private networks are blocked by default

Driving localhost needs:

```bash
obscura serve --allow-private-network
```

Without it, requests to private addresses are blocked by the SSRF guard and
surface as `ConnectionError`.

## Render is a build-time feature

Since 0.2.0 there are four builds per platform. The `-no-render` ones omit the
paint engine and refuse `Page.captureScreenshot` and `Page.printToPDF`.

**`--version` reports the same string for all four**, so the only reliable way to
identify a build is to ask for a capture and see whether it refuses — or compare
checksums, which `scripts/obscura/install.sh` prints for you.

## Stealth takes two halves

Getting past commercial anti-bot layers needs **both**:

1. the `-stealth` release build, which carries TLS impersonation, and
2. the `--stealth` flag on the process — `obscura --stealth serve`.

Drop either and the handshake falls back to Obscura's native TLS stack while the
User-Agent still claims Chrome. That mismatch is exactly what the anti-bot layer
reads.

Neither half announces itself: the flag is accepted without warning on a
non-stealth build, and all four builds answer `--version` identically. Compare
checksums instead — `scripts/obscura/install.sh` prints them.

And the fingerprint buys you the right to be *challenged*, not the right to get
in: a cold session still has to earn its clearance cookies, and a hammered IP may
not be allowed to at all. Expect intermittent failure there, and space runs out.

Worked example: [`examples/stealth.rb`](../examples/stealth.rb). Note how it
checks the *body* for a block marker rather than the HTTP status — the
interstitial answers 200 with a plausible document, so every request "succeeds".

## PDF is raster-backed

Obscura reports `print-media-raster`. A generated PDF has zero font objects and no
extractable text. Header/footer rendering and CSS `@page` sizing are not
implemented. See [PDF](pdf.md).

## Lifted in 0.1.11 — do not reintroduce workarounds for these

- **The ~500–700 KB message ceiling is gone.** It is 64 MiB now, so
  [`#html`](content.md) reads `outerHTML` in one round trip. Verified with 8 MiB
  and 16 MiB strings.
- **`fetch` is routed**, so [`#post`](http.md) uses it. `#xhr_post` remains as a
  deprecated alias.
- **Cookies no longer leak between connections.** Each connection owns its
  browser context.
- **`form.submit()` and `form.requestSubmit()` genuinely differ.**
  [`#submit`](forms.md) uses `requestSubmit` with no fallback, because falling
  back would silently skip validation and any listener.

## A measurement habit worth copying

Twice while building this gem, **byte size lied about whether an option
applied**:

- An A4 PDF of a page weighed *exactly* as much as the Letter one. Only
  `/MediaBox` showed the paper size had changed.
- A jpeg at quality 20 weighed almost the same as the default, which read as
  "quality ignored". Sweeping the full range showed it working fine.

Read the artifact — `/MediaBox` for PDFs, the header for images — or sweep the
whole range. Do not infer from file size, and do not document a limitation you
have not reproduced deliberately.
