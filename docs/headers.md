# Headers

Extra HTTP headers sent with the page's requests, as a small mutable collection.

```ruby
page.headers.set("X-Token" => "abc")         # replaces the whole table
page.headers.add("Accept-Language" => "es")  # merges into it
page.headers["X-Token"]                      # => "abc"
page.headers["X-Trace"] = "1"                # one at a time
page.headers.delete("X-Token")
page.headers.clear
```

## Reading

```ruby
page.headers.get        # => {"X-Token" => "abc"}
page.headers.to_h       # alias
page.headers["x-token"] # => "abc"   — names match case-insensitively
page.headers.key?("X-Token")
page.headers.empty?
page.headers.size
```

`#get` returns a **copy**, so mutating it does not change what gets sent.

### What "reading" actually means here

CDP is write-only about this. `Network.setExtraHTTPHeaders` sets the table, and
there is no matching getter — Obscura answers `Network.getExtraHTTPHeaders` with
`Unknown Network method`.

So `#get` reports **what this object last sent**, which is the only readable
record that exists. Change the headers by another route — a raw
[`#command`](pages.md), a `Headers` on another page — and this object will not
know about it.

## Writing

| Method | Effect |
|---|---|
| `set(hash)` | Replaces the entire table |
| `add(hash)` | Merges, replacing only the names given |
| `[]=(name, value)` | Sets one, leaves the rest |
| `delete(name)` | Removes one, returns its old value or `nil` |
| `clear` | Removes everything |

`set` replacing rather than merging is not a choice — it mirrors what the browser
does with the command.

```ruby
page.headers.set("X-One" => "1")
page.headers.set("X-Two" => "2")
page.headers.get                    # => {"X-Two" => "2"}   — X-One is gone

page.headers.add("X-Three" => "3")
page.headers.get                    # => {"X-Two" => "2", "X-Three" => "3"}
```

Names and values are stringified, because that is what CDP accepts:

```ruby
page.headers.set(:"X-Num" => 42)
page.headers.get                    # => {"X-Num" => "42"}
```

Header names are case-insensitive per RFC 9110, so writing a name that differs
only in case **replaces** the existing entry rather than sending both:

```ruby
page.headers.add("x-token" => "old")
page.headers.add("X-Token" => "new")
page.headers.get                    # => {"X-Token" => "new"}
```

Two spellings of one header is always a bug, never an intent.

## Overriding the User-Agent

It is just a header:

```ruby
page.headers.set("User-Agent" => "Obxcura/1.0")
```

`Network.setUserAgentOverride` also works if you want it through
[`#command`](pages.md), but for navigation this is enough.

## Two things that will surprise you

Both measured against Obscura 0.2.0, and both are why this page exists.

### The scope is the connection, not the page

The API hangs off `Page` because that is the only session the command works
from — sent without a session it is accepted and **silently does nothing**. But
Obscura keeps one table per *connection*.

```ruby
a = browser.create_page
b = browser.create_page

a.headers.set("X-Who" => "A")
b.headers.set("X-Who" => "B")

# BOTH pages now send X-Who: B. Last write wins, browser-wide.
```

Two pages on one browser cannot carry different headers. If you need that, open a
second `Browser` — a separate connection has its own table.

```ruby
one = Obxcura.start
two = Obxcura.start

one.create_page.headers.set("X-Tenant" => "acme")
two.create_page.headers.set("X-Tenant" => "globex")   # independent
```

### They cover navigation only

Obscura attaches extra headers to the document and its subresources, never to
requests started from script. A [`#post`](http.md) — or any in-page `fetch` or
`XMLHttpRequest` — does not carry them.

```ruby
page.headers.set("X-Token" => "abc")

page.goto(url)                                  # sends X-Token
page.post(url, body, "application/json", {})    # does NOT
```

That is why `#post` takes its own `headers` argument, and why you often need
both:

```ruby
page.headers.set("X-Token" => token)                              # navigation
page.post(url, body, "application/json", { "X-Token" => token })  # fetch
```

This is the same boundary that keeps script-initiated requests out of
[`#network_log`](http.md) — Obscura's network layer treats navigation and script
traffic differently throughout.

## Persistence

Headers survive navigation and reloads. They last until you change or clear them,
or the connection drops.

```ruby
page.headers.set("X-Token" => "abc")
page.goto(url_one)    # sends it
page.goto(url_two)    # still sends it
page.reload           # still sends it
```

A fresh `Browser` starts with an empty table.
