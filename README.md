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

You also need the **`obscura` browser binary**, which is a separate project. The
repo ships an installer for it:

```bash
scripts/obscura/install.sh
```

That pulls the latest release for your platform into `/usr/local/bin` (asking for
`sudo` only if the prefix is not writable), then verifies the install and prints
the checksums.

```bash
scripts/obscura/install.sh --version v0.2.0      # pin a release
scripts/obscura/install.sh --prefix ~/.local/bin # no sudo
scripts/obscura/install.sh --no-stealth          # plain build
scripts/obscura/install.sh --no-render           # smaller, no screenshot/pdf
scripts/obscura/install.sh --help
```

Prefer it to a manual download, because the packaging has sharp edges:

- **Since 0.2.0 there are four builds per platform**, and the suffix decides what
  works:

  | Asset suffix | Render engine | Stealth |
  |---|---|---|
  | *(none)* | yes | no |
  | `-stealth` | yes | yes |
  | `-no-render` | no | no |
  | `-no-render-stealth` | no | yes |

  The script defaults to **`-stealth`**: it carries the render engine that
  `#screenshot` and `#pdf` need, *and* it is the build that gets past commercial
  bot detection. `--no-render` trades both away for a smaller download.
- **`--version` cannot tell the builds apart** — all four of a release report the
  same string. That is why the script prints checksums: they are the only way to
  identify later which build is actually installed.
- **The archive holds two binaries**, `obscura` and `obscura-worker`, and `serve`
  looks for the worker as a *sibling*. The script always moves the pair, since
  installing one alone silently mixes builds.
- **On macOS it removes the target before copying.** Overwriting a binary in
  place leaves a stale cached code signature on that inode, and the kernel then
  `SIGKILL`s it on exec — even though the bytes are fine.

Driving anything on localhost also needs `--allow-private-network`, which is off
by default:

```bash
obscura serve --allow-private-network
```

## Usage

Start the browser first (defaults to port 9222):

```bash
obscura serve
```

Then:

```ruby
require "obxcura"

browser = Obxcura::Browser.new              # or Obxcura.start
begin
  page = browser.go_to("https://example.com")

  page.title                                # => "Example Domain"
  page.current_url                          # => "https://example.com/"
  page.html                                 # rendered DOM, post-JS
  page.evaluate("1 + 2")                    # => 3

  page.at_css("h1").text                    # => "Example Domain"
  page.css("a").map { |a| a["href"] }

  page.at_css("#username").type("guillermo")
  page.at_css("form").submit

  page.screenshot(path: "shot.png")
  page.pdf(path: "page.pdf", paper: :a4)
ensure
  browser.quit                              # always, so targets don't leak
end
```

That is the whole shape of it: a `Browser` owns the connection, a `Page` is a
target on it, and `#at_css` / `#css` hand back live `Node` handles you can read
from and act on.

## Documentation

Full reference in [`docs/`](docs/README.md), one page per area:

| | |
|---|---|
| [Connecting](docs/connecting.md) | `Obxcura.start`, `Browser.new`, ports, timeouts, shutdown |
| [Pages](docs/pages.md) | `#goto`, `#refresh`, `#close`, raw `#command` |
| [Reading content](docs/content.md) | `#html`, `#title`, `#current_url` |
| [Querying the DOM](docs/dom.md) | `#at_css`, `#css`, and every `Node` method |
| [Running JavaScript](docs/javascript.md) | `#evaluate`, `#evaluate_func`, `#call_on` |
| [Forms and input](docs/forms.md) | `#focus`, `#type`, `#submit`, `#value` |
| [HTTP from the page](docs/http.md) | `#post`, `#network_log`, `#cookies` |
| [Screenshots](docs/screenshots.md) | `#screenshot` and every option |
| [PDF](docs/pdf.md) | `#pdf` and every option |
| [Errors](docs/errors.md) | The exception hierarchy, and what does *not* raise |
| [Browser constraints](docs/constraints.md) | Obscura limits that shape this API |

Runnable examples live in [`examples/`](examples/).

Two constraints are worth knowing before you write anything, both covered in
[Browser constraints](docs/constraints.md): Obscura stops running background
JavaScript shortly after `load`, so `goto` + `sleep` does not do what you expect;
and an in-page `throw` comes back as `nil` rather than raising.

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
The `#screenshot` and `#pdf` specs skip the same way on a `-no-render` build, so
run them against a build that has the render engine — either the default from
`scripts/obscura/install.sh` or the unsuffixed asset — if you touch either.

## Contributing

Bug reports and pull requests are welcome at https://github.com/memoxmrdl/obxcura.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
