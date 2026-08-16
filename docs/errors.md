# Errors

```
StandardError
└── Obxcura::Error
    ├── Obxcura::TimeoutError
    ├── Obxcura::ProtocolError
    └── Obxcura::ConnectionError
```

Everything the gem raises descends from `Obxcura::Error`, so one rescue catches
the family:

```ruby
begin
  page = browser.go_to(url)
rescue Obxcura::Error => e
  warn "#{e.class}: #{e.message}"
end
```

`ArgumentError` is the exception to that: bad arguments are a programming
mistake, not a browser condition, so they stay a plain Ruby `ArgumentError`.

## `ConnectionError`

The browser endpoint could not be reached, or a request never left the page.

```ruby
Obxcura::Browser.new(port: 9999)
# => Obxcura::ConnectionError: Could not reach Obscura at 127.0.0.1:9999 ...
#    Is it running? Start it with: obscura serve
```

Also raised by [`#post`](http.md) when the request never reached the server —
blocked by CORS or the private-network guard, mixed origin, dead host. Driving
localhost needs `obscura serve --allow-private-network`.

## `TimeoutError`

A CDP command, the initial connect, or a page load did not answer in time.

```ruby
# default 30s, per command
Obxcura::Browser.new(timeout: 60)

# or for one call
page.evaluate_func("function(){ /* slow */ }", timeout: 60)

# or bounded inside the page
page.post(url, body, "application/json", {}, timeout: 5)
```

Before raising the timeout, ask why it is slow. The usual cause is not a slow
page but a **starved connection**: one command awaiting a promise that never
settles blocks every other command on that socket for ~30s. More timeout does not
help there — see [Browser constraints](constraints.md).

## `ProtocolError`

Obscura reported a protocol-level error, or CDP surfaced an exception.

```ruby
page.command("Page.printToPDF", displayHeaderFooter: true)
# => Obxcura::ProtocolError: Page.printToPDF does not yet support headers and footers

page.at_css("h1").submit
# => Obxcura::ProtocolError: node is not a form and has no ancestor form
```

Its messages come from the browser and are usually specific enough to act on
directly. Read them before assuming the gem is wrong.

## What does *not* raise

Two things worth internalising, because both look like success:

**A JavaScript `throw` returns `nil`.** In-page throws are swallowed; you get
`undefined`, indistinguishable from a function that returned nothing. This is why
the gem's own JavaScript returns `{ error: ... }` sentinels and raises from Ruby.
Write yours the same way — see [Running JavaScript](javascript.md).

```ruby
page.evaluate("(function(){ throw new Error('boom') })()")   # => nil
```

**An HTTP error status is not an exception.** `#post` returns a hash for any
reply, 4xx and 5xx included:

```ruby
result = page.post(url, body, "application/json", {})
result["ok"]       # => false
result["status"]   # => 500
```

Check `ok`/`status` yourself.

And a missing element is `nil`, not a raise:

```ruby
page.at_css(".nope")        # => nil
page.at_css(".nope")&.text  # => nil
page.css(".nope")           # => []
```

## Render-feature errors

`#screenshot` and `#pdf` map the browser's refusal on a `-no-render` build to an
`Obxcura::Error` that names the fix, instead of leaking a raw `ProtocolError`:

```ruby
page.screenshot
# => Obxcura::Error: This Obscura build has no render engine, so it cannot take
#    screenshots. Install the unsuffixed release asset (the `-no-render` ones omit it).
```

Every other `ProtocolError` passes through untouched.
