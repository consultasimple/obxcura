# Screenshots

```ruby
page.screenshot                                  # => raw PNG bytes
page.screenshot(path: "shot.png")                # writes it, returns the path
page.screenshot(path: "shot.jpg", quality: 80)   # format from the extension
page.screenshot(full_page: true)                 # whole document
page.screenshot(clip: { x: 0, y: 0, width: 300, height: 200, scale: 2 })
```

Runnable version: [`examples/screenshot.rb`](../examples/screenshot.rb).

> **Needs a render build.** Obscura gained a paint engine in 0.2.0, but the
> `-no-render` archives of the *same version* omit it and refuse the command.
> `#screenshot` reports that as an `Obxcura::Error` naming the asset to install.
> `scripts/obscura/install.sh` picks a build that has it by default.

## Return value

Raw image bytes, `BINARY` encoding. Base64 is a CDP transport detail and is
decoded for you, so you can write the result anywhere or hand it to an image
library without another step.

With `path:` the bytes are written for you and the **path** comes back instead.

```ruby
bytes = page.screenshot
bytes.encoding            # => #<Encoding:BINARY (ASCII-8BIT)>
bytes.start_with?("\x89PNG".b)   # => true

page.screenshot(path: "out.png")  # => "out.png"
```

## `format:`

`:png` (default), `:jpeg`, `:webp`.

```ruby
page.screenshot(format: :jpeg)
```

When you pass `path:` and no `format:`, the extension decides — `.png`, `.jpg`,
`.jpeg`, `.webp`. An explicit `format:` always wins over the extension.

```ruby
page.screenshot(path: "shot.jpg")                 # jpeg
page.screenshot(path: "shot.jpg", format: :png)   # png, despite the name
```

An unknown format raises `ArgumentError` before any round trip.

## `quality:`

0–100, **`:jpeg` only**.

```ruby
page.screenshot(format: :jpeg, quality: 20)
```

- `:png` ignores it, so passing it there raises `ArgumentError` rather than
  silently doing nothing.
- `:webp` **rejects** it. Obscura's webp encoder is lossless and refuses any
  quality at all, including 0 and 100. Also an `ArgumentError` here.

A note on judging the effect: on a smooth gradient, quality 20 and the default
come out nearly the same size, which reads as "ignored" and is not. Sweep the
range before concluding anything — q1 ≈ 25.8 KB against q100 ≈ 57.2 KB on the
same page.

## `full_page:`

Captures the whole document instead of the viewport.

```ruby
page.screenshot(full_page: true)
```

On a page that already fits the viewport this changes nothing — full page and
viewport are the same height. On a tall page the difference is the whole point:
1280x720 becomes 1280x2400 on the test fixture.

Mutually exclusive with `clip:`; passing both raises `ArgumentError`, because CDP
would otherwise silently pick one.

## `clip:`

A region of the page, in CSS pixels.

```ruby
page.screenshot(clip: { x: 0, y: 0, width: 300, height: 200 })
```

| Key | Default | Meaning |
|---|---|---|
| `x:` | `0` | Left edge |
| `y:` | `0` | Top edge |
| `width:` | — | Required |
| `height:` | — | Required |
| `scale:` | `1` | Raster multiplier |

`scale:` genuinely rasterises larger — it is not a metadata flag. A 300x200 clip
at `scale: 2` produces a 600x400 image, which is how you get retina-density
crops.

Omitting `width:` or `height:` raises `ArgumentError`.

## Errors

| Cause | Raised |
|---|---|
| Unknown format | `ArgumentError`, before the round trip |
| `quality:` with `:png` or `:webp` | `ArgumentError`, before the round trip |
| `quality:` outside 0..100 | `ArgumentError`, before the round trip |
| `full_page:` together with `clip:` | `ArgumentError`, before the round trip |
| `clip:` without dimensions | `ArgumentError`, before the round trip |
| Browser has no render engine | `Obxcura::Error`, naming the asset to install |

## What screenshots are actually for

Not proof that things worked. Proof of what the browser *received* when they did
not.

An empty `page.css("h3")` on a page you expected results from sends most people
straight to rewriting the selector. One screenshot ends that in seconds — the
anti-bot interstitial is right there in the image, and the selector was never the
problem. `examples/screenshot.rb` demonstrates exactly that against Google.
