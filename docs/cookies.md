# Cookies

`page.cookies` is the browser's cookie jar seen from one page: enumerable over
the cookies that page's URL would send, and writable.

```ruby
page = browser.go_to("https://example.com/app")

page.cookies.map { |c| c["name"] }   # what this URL would send
page.cookies["session"]              # => { "name" => "session", "value" => "...", ... }
page.cookies.all                     # every cookie the connection holds
page.cookies.set("token", "abc")
page.cookies.remove("token")
page.cookies.clear
```

Cookies are raw CDP hashes with string keys, and the shape going out is the same
as the shape coming in — so a cookie read here can be replayed into another
browser as is.

Every read hits the browser. Nothing is cached; two calls are two round trips.

## Reading

| | |
|---|---|
| `#each` / `#map` / any `Enumerable` | the cookies the current URL would send |
| `#[](name)` | one of those by name, or `nil` |
| `#size` / `#empty?` | over that same scoped view |
| `#for_url(url)` | the cookies some *other* URL would send |
| `#all` | the whole connection's jar, unfiltered |

The scoped view includes **`HttpOnly` cookies, which `document.cookie` cannot
see** — and since the session cookie is usually HttpOnly, that is the whole
reason to read them over CDP instead of from the page:

```ruby
page.evaluate("document.cookie")   # "consent=1"
page.cookies["session"]["value"]   # "s%3A9f2c..."
```

On `about:blank` — a page that has not navigated anywhere — the scoped view is
empty while `#all` still shows the jar.

## Writing

```ruby
page.cookies.set("token", "abc")
page.cookies.set("token", "abc", path: "/app", http_only: true, expires: Time.now + 3600)
page.cookies.set("token", "abc", domain: "example.com", secure: true, same_site: "Strict")
```

Options: `url:`, `domain:`, `path:`, `secure:`, `http_only:`, `same_site:`
(`"Strict"`, `"Lax"`, `"None"`), and `expires:` — a `Time`, `Date`, `DateTime`,
or epoch seconds.
Anything else raises `ArgumentError`, because the browser accepts unknown
parameters and silently ignores them.

`same_site:` is validated for the same reason: Obscura takes `"Nope"` without
complaint and stores `Lax`.

The browser refuses a cookie that belongs nowhere (`missing required
name/domain (or url)`), so with neither `url:` nor `domain:` given the page's
current URL is used. On `about:blank` there is nothing to fall back to and both
`#set` and `#remove` raise `ArgumentError` before sending anything — pass
`domain:` to work without a page URL.

A missing name raises too. That one guards the replay flow above: if the read
came back `nil`, `set(nil)` should say so rather than quietly write a cookie
with an empty name.

### Replaying a saved cookie

`#set` also takes a whole cookie hash, which is how you move a session between
browsers:

```ruby
saved = page.cookies["session"]      # from a logged-in browser

fresh = other_browser.go_to("https://example.com/")
fresh.cookies.set(saved)             # now logged in too
```

The keys a read carries but a write cannot take (`size`, `session`,
`sourcePort`, ...) are dropped for you, and the `expires: -1` of a session
cookie is understood as "no expiry" rather than a date in 1969.

### Removing

```ruby
page.cookies.remove("session")                 # => true
page.cookies.remove("session", path: "/deep")  # a specific one
```

`#remove` returns whether a cookie *of that name* went away, and that return
value earns its keep: **`Network.deleteCookies` compares the path exactly.** A
delete aimed at `/cookies` does not touch a cookie set on `/`, and one aimed at
`/` does not touch a cookie set on `/deep` — measured, and silent either way.

The answer is deliberately about the one cookie rather than the jar. The jar
belongs to the connection and every page on it can write, so comparing whole
snapshots would report somebody else's cookie as this delete.

So by default `#remove` looks the cookie up in the jar first and deletes it at
the exact domain and path reported there. Pass `domain:` or `path:` yourself to
skip that lookup and send exactly what you asked for.

`#clear` drops **every** cookie on the connection, not just this page's — it is
the same call as [`browser.clear_cookies`](connecting.md).

## What the browser does that this API works around

**The jar belongs to the connection.** Obscura gives each connection its own
browser context, so a second `Browser` starts clean — but every page on one
connection shares one jar, and a page that never navigated anywhere still sees
all of it. `#all` is that jar; the enumerable view is one URL's slice of it.

**Cookie reads ignore the URL you ask about.** `Network.getCookies` takes a
`urls:` parameter and Obscura ignores it: that call, `Storage.getCookies` and
`Network.getAllCookies` all return the same connection-wide jar, whatever URL
you name and whichever page's session you send it from. Asking about
`https://example.com/` while parked on localhost returns the localhost cookies.
So the scoping happens in Ruby, following RFC 6265 §5.1.3–5.1.4 — domain, path,
`Secure`, then expiry. Ports are not part of cookie scope and are ignored.

**An expired cookie stays in the jar.** The browser simply stops sending it, so
`#all` can show you something that will never go on the wire. The scoped view
drops it.

**Host-only cookies cannot be told apart.** A cookie set with
`Domain=example.com` is a *domain* cookie and reaches `www.example.com`; one set
without the attribute is host-only and does not. Chrome records the difference by
storing the first as `.example.com` — Obscura stores it verbatim, so nothing
distinguishes them. Domain matching is therefore applied to every entry, which
can include a host-only cookie on a subdomain it would not really be sent to.
Over-reporting beats losing the session cookie you came for.

See [Browser constraints](constraints.md) for the rest of the family.
