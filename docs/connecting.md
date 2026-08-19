# Connecting

Obxcura does not start the browser. It connects to an `obscura serve` you are
already running, over one WebSocket.

```bash
obscura serve                             # 127.0.0.1:9222
obscura serve --allow-private-network     # required to drive localhost
```

## `Obxcura.start(**options)`

Sugar for `Browser.new`. Same options.

```ruby
browser = Obxcura.start                   # 127.0.0.1:9222
browser = Obxcura.start(port: 9333)
```

## `Browser.new(host:, port:, timeout:)`

| Option | Default | Meaning |
|---|---|---|
| `host:` | `"127.0.0.1"` | Host `obscura serve` listens on |
| `port:` | `9222` | Its CDP port |
| `timeout:` | `30` | Seconds to wait for any CDP reply |

Connecting is eager: `new` fetches `/json/version`, opens the socket and blocks
until the WebSocket handshake completes.

```ruby
browser = Obxcura::Browser.new(port: 9222, timeout: 60)
```

If nothing is listening you get an `Obxcura::ConnectionError` naming the address,
not a bare `Errno::ECONNREFUSED`.

## One browser, one connection, many pages

```ruby
browser = Obxcura.start
a = browser.create_page
b = browser.go_to("https://example.com")
browser.pages          # => [a, b]
```

Every page is a CDP target with its own session, multiplexed over that single
socket. Replies route by command id; events route by session id.

**Fast commands interleave fine, but one blocked command stalls the whole
connection.** A `Runtime.evaluate` awaiting a promise that never settles starves
every other command on that socket — other pages included — until the browser
gives up on it, which takes ~30s in Obscura 0.2.0. The blast radius is the
connection, not the session: a second `Browser` stays responsive throughout. See
[Browser constraints](constraints.md).

## Inspecting the browser

```ruby
browser.version    # => {"Browser" => "Chrome/145.0.0.0", "Protocol-Version" => "1.3", ...}
browser.targets    # => [{"targetId" => "...", "type" => "page", "url" => "..."}, ...]
browser.host       # => "127.0.0.1"
browser.port       # => 9222
```

`#version` is a plain HTTP GET of `/json/version`, so it works before the socket
is up. `#targets` is a CDP call and covers every target, not just your pages.

## Cookies

```ruby
browser.clear_cookies    # => nil
```

Since Obscura 0.1.11 each connection owns its own browser context, so cookies do
not leak between `Browser` instances. This only resets state *within* one
connection. Because `obscura serve` is long-lived and `#quit` just drops the
socket, opening a fresh `Browser` is the other way to get a clean jar.

Reading and writing cookies is per page — see [Cookies](cookies.md).

## Shutting down

```ruby
browser.close     # closes every page, then drops the connection
browser.quit      # alias
```

Always in an `ensure`, so a raised spec or script does not leave targets behind:

```ruby
browser = Obxcura.start
begin
  page = browser.go_to("https://example.com")
  puts page.title
ensure
  browser.quit
end
```

`#quit` closes each page over the same connection, so it waits on that socket
like anything else. If a page has a command wedged, prefer dropping the socket
outright with `browser.client.close` — nothing then waits on the abandoned work.

## Raw CDP

`Browser#command` is delegated to the client and sends browser-level commands
(no session):

```ruby
browser.command("Target.getTargets")
```

For page-scoped commands use `Page#command` — see [Pages](pages.md).
