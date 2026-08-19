# HTTP from the page

## `Page#post(url, payload, content_type, headers, timeout: nil)`

POSTs from inside the page context via `fetch`, so the request carries the page's
origin, cookies and session — which is the whole reason to do it here instead of
with Net::HTTP.

```ruby
result = page.post(
  "https://api.example.com/orders",
  JSON.generate(id: 42),
  "application/json",
  { "X-Request-Id" => "abc123" }
)

result["status"]   # => 201
result["ok"]       # => true
result["body"]     # => "{\"created\":true}"
```

All four values are positional and required. Pass `{}` for no extra headers.

Every value crosses into the page as a real argument, never interpolated into
JavaScript source.

### Return value

A hash on **any** HTTP reply, including 4xx and 5xx:

```ruby
result = page.post(url, "", "text/plain", {})
result["ok"]       # => false
result["status"]   # => 500
```

An error status is not an exception. Check `ok`/`status` yourself.

### `timeout:`

Seconds. Enforced **in the page**, by racing the fetch against a timer, so a
server that accepts the connection and never answers fails in about `timeout`
rather than waiting out the 30s CDP reply timeout. Raises
`Obxcura::TimeoutError`.

```ruby
page.post(url, body, "application/json", {}, timeout: 5)
```

The race is deliberate and not `AbortSignal.timeout`. Obscura accepts the signal,
but when the abort fires the rejection is swallowed and the call returns
`undefined` — the same vanishing-throw behaviour described in
[Running JavaScript](javascript.md). A rejection cannot carry the reason across,
so the reason has to arrive as a resolved value. The underlying request is still
aborted once the timer wins, purely so it stops occupying the connection.

### `ConnectionError`

Raised when the request never reached the server at all — blocked by CORS or the
private-network guard, a mixed-origin refusal, a dead host:

```ruby
page.post("http://127.0.0.1:9999/x", "", "text/plain", {})
# => Obxcura::ConnectionError: POST http://127.0.0.1:9999/x failed: ...
```

Driving localhost needs `obscura serve --allow-private-network`; without it the
SSRF guard blocks the request and you land here.

### `#xhr_post`

Deprecated alias, from when Obscura did not route `fetch` and this had to use
`XMLHttpRequest`. Same method.

## `Page#network_log`

Requests this page issued, oldest first.

```ruby
page.network_log
# => [{ url: "https://example.com/", request_id: "1", finished: true }, ...]
```

Returns a copied snapshot, safe to iterate while the page keeps loading.

**Scope is narrow, and this is the important part.** Obscura emits Network events
for requests the *navigation* drives — the document and its subresources — but
not for anything started from script. A `#post`, or any in-page `fetch` /
`XMLHttpRequest`, **never appears here**. That was measured against 0.1.11 and
re-measured on 0.2.0, and it holds despite upstream notes suggesting otherwise.

So `#network_log` answers "what did loading this page fetch?", never "did my POST
go out?". For the latter, read `#post`'s return value.

```ruby
page = browser.go_to("https://example.com")
page.network_log.length          # documents + subresources

page.post(url, body, "application/json", {})
page.network_log.length          # unchanged
```

## Cookies

Cookies have their own page now: [Cookies](cookies.md).

```ruby
page.cookies["session"]         # what the current URL would send
page.cookies.set("token", "x")
browser.clear_cookies           # the whole connection's jar
```

Since 0.1.11 each connection owns its own browser context, so cookies do not leak
between `Browser` instances. A fresh `Browser` is the cleanest way to get a clean
jar.
