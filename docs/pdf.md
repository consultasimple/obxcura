# PDF

```ruby
page.pdf                                        # => raw PDF bytes
page.pdf(path: "report.pdf")                    # writes it, returns the path
page.pdf(paper: :a4, print_background: true)
page.pdf(landscape: true, margin: 0)
page.pdf(scale: 0.5, page_ranges: "1-3")
```

Runnable version: [`examples/pdf.rb`](../examples/pdf.rb).

> **Needs a render build**, same as [screenshots](screenshots.md). The
> `-no-render` archives refuse `Page.printToPDF`, and `#pdf` reports that as an
> `Obxcura::Error` naming the asset to install.

## The one limitation that decides whether you can use this

**The output is raster-backed.** Obscura reports `print-media-raster`: each page
is a drawn image. A generated document has **zero font objects and no extractable
text** — measured, not assumed.

So a PDF from here cannot be searched, selected, copied from, indexed, or read by
a screen reader. If you need the text, use [`#html`](content.md) and generate the
document yourself. If you need a faithful *picture* of the page — an invoice, a
receipt, a visual record — this is exactly right.

## Return value

Raw PDF bytes, `BINARY` encoding, base64 already decoded. With `path:` the bytes
are written and the **path** comes back.

```ruby
bytes = page.pdf
bytes.start_with?("%PDF-")    # => true

page.pdf(path: "out.pdf")     # => "out.pdf"
```

## Paper size

Either a name or explicit inches — not both.

```ruby
page.pdf(paper: :a4)
page.pdf(paper_width: 8.27, paper_height: 11.69)
```

| Name | Inches | Points |
|---|---|---|
| `:letter` *(default)* | 8.5 x 11 | 612 x 792 |
| `:legal` | 8.5 x 14 | 612 x 1008 |
| `:tabloid` | 11 x 17 | 792 x 1224 |
| `:a3` | 11.7 x 16.54 | 842 x 1191 |
| `:a4` | 8.27 x 11.69 | 595 x 842 |
| `:a5` | 5.83 x 8.27 | 420 x 595 |

An unknown name raises `ArgumentError` listing the valid ones. Combining `paper:`
with `paper_width:`/`paper_height:` also raises, rather than quietly preferring
one.

Obscura accepts 0–200 inches and rejects anything outside that itself.

> Checking whether paper size applied? Read the PDF's `/MediaBox`, not the file
> size. An A4 render of a page can weigh **exactly** as many bytes as the Letter
> one while being a different document. Byte length is a terrible proxy here.

## `landscape:`

Swaps the page box — 612x792 becomes 792x612.

```ruby
page.pdf(landscape: true)
```

## `print_background:`

Paints backgrounds and images that print stylesheets would otherwise drop. Off by
default, matching print behaviour.

```ruby
page.pdf(print_background: true)
```

## `scale:`

`0.1` to `2.0`. Smaller fits more of the document per page.

```ruby
page.pdf(scale: 0.5)    # roughly halves the page count
```

Outside that range raises `ArgumentError` before the round trip.

## `margin:`

Inches. One number for all four sides, or per side.

```ruby
page.pdf(margin: 0)
page.pdf(margin: 0.5)
page.pdf(margin: { top: 1.5, bottom: 1.5, left: 1, right: 1 })
```

Any subset of `top:`, `bottom:`, `left:`, `right:` is fine; the rest keep the
browser default. Negative margins, or margins leaving no printable area, are
rejected by Obscura.

## `page_ranges:`

A CDP range string.

```ruby
page.pdf(page_ranges: "1")
page.pdf(page_ranges: "1-3")
page.pdf(page_ranges: "1,4-5")
```

Obscura validates it: a malformed range and a range selecting no pages both raise
`Obxcura::ProtocolError` with a clear message.

## Not implemented upstream

Two CDP options exist in the protocol but not in Obscura 0.2.0, so `#pdf`
deliberately does not expose them:

| Option | Obscura's answer |
|---|---|
| `displayHeaderFooter` | `does not yet support headers and footers` |
| `preferCSSPageSize` | `does not yet support CSS @page sizing` |

You can still ask through [`#command`](pages.md) and get that error yourself —
which is better than the gem accepting the option and dropping it.

Print stylesheets *are* honoured, so `@media print` rules apply.

## Errors

| Cause | Raised |
|---|---|
| Unknown paper name | `ArgumentError`, before the round trip |
| `paper:` with explicit dimensions | `ArgumentError`, before the round trip |
| `scale:` outside 0.1..2.0 | `ArgumentError`, before the round trip |
| Paper outside 0–200 inches | `Obxcura::ProtocolError` from the browser |
| Bad or empty `page_ranges:` | `Obxcura::ProtocolError` from the browser |
| Negative margins | `Obxcura::ProtocolError` from the browser |
| Browser has no render engine | `Obxcura::Error`, naming the asset to install |

The split is deliberate: the gem validates what only Ruby knows — a paper *name*,
contradictory options — and lets Obscura report the rest, because its messages
are already precise and duplicating them just invites drift.
