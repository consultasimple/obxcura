# Reading content

Three reads, all on `Page` (delegated to its main `Frame`).

```ruby
page.html          # rendered outerHTML, post-JS
page.body          # alias of #html
page.title         # document.title
page.current_url   # window.location.href
```

## `#html` / `#body`

The live, post-JavaScript document — `document.documentElement.outerHTML`, not
the bytes the server sent. What you get is what the DOM looks like now.

```ruby
page = browser.go_to("https://example.com")
page.html    # => "<html><head>...</head><body>...</body></html>"
```

**One round trip, at any size.** Obscura's single-message ceiling is 64 MiB as of
0.1.11, so even a very large document comes back whole. Multi-megabyte reads are
routine and verified up to 16 MiB.

If you are looking for the chunked-read helper an older version had
(`read_string`, `EVALUATE_CHUNK`, `window.__obxcura_read`): it is gone, and it
should stay gone.

## `#title`

```ruby
page.title    # => "Example Domain"
```

Worth a sanity check on sites that gate traffic. If `#title` comes back as the
URL you requested rather than a real title, you are almost certainly looking at
an interstitial, not the page you wanted — take a [screenshot](screenshots.md)
and look at it before blaming your selectors.

## `#current_url`

```ruby
page.current_url    # => "https://www.example.com/"
```

Read after navigation to see where you actually ended up — redirects, appended
tracking parameters, consent hops.

```ruby
page.goto("https://example.com/old")
page.current_url    # => "https://example.com/new"
```

## Parsing

There is no Ruby-side HTML parser in the dependency list, and none is needed:
`#at_css` and `#css` run `querySelector` **in the browser** and hand back live
node handles. See [Querying the DOM](dom.md).

If you genuinely want an offline document — to diff it, store it, or run XPath —
take `#html` and feed it to whatever parser you like. That is your dependency,
not the gem's.
