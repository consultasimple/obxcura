# Querying the DOM

Selector queries run **in the browser** and return live `Node` handles, not
parsed copies. A `Node` is backed by a CDP remote object, so every read on it
reflects the DOM as it is now.

```ruby
page.at_css("h1")        # => Obxcura::Node, or nil
page.css("a")            # => [Obxcura::Node, ...] (empty if none)
```

## `#at_css(selector)`

First match, or `nil`. Available on `Page`, `Frame` and `Node`.

```ruby
heading = page.at_css("#greeting")
heading&.text            # => "Hello Obxcura"

page.at_css(".nope")     # => nil
```

Prefer `&.` — a missing element is `nil`, not an exception.

## `#css(selector)`

Every match, as an array. Empty when nothing matches; it never returns `nil`.

```ruby
page.css("a").map { |a| a["href"] }
page.css("li").length
```

An empty result on a page you expected content from is worth a
[screenshot](screenshots.md) before you start rewriting the selector — see the
Google example in `examples/screenshot.rb`.

## Scoping to a node

`Node#at_css` searches *within* that node:

```ruby
row  = page.at_css("tr.selected")
name = row.at_css("td.name").text
```

There is no `Node#css` — reach for `#evaluate_func` if you need all descendants
of a specific element.

## Node reads

```ruby
node.text          # textContent of the node and its descendants
node.value         # value of a form control, or nil
node["href"]       # getAttribute("href"), or nil
node.attribute("href")   # alias of #[]
node.outer_html    # this element serialized, including itself
```

```ruby
link = page.at_css("a.download")
link.text          # => "Download"
link["href"]       # => "/files/report.pdf"
link.outer_html    # => "<a class=\"download\" href=\"/files/report.pdf\">Download</a>"
```

Writing to a node — focusing, typing, submitting — is in
[Forms and input](forms.md).

## How resolution works

Obscura cannot serialize a DOM node by value. Returning one over
`returnByValue` yields an internal stub carrying an `_nid`, which is useless on
its own. The gem resolves that `_nid` through `DOM.resolveNode` into a real
remote object handle and wraps it in a `Node`.

You rarely care, except for two consequences:

- **Every query costs an extra round trip** for the resolution. `page.css("li")`
  on a hundred items resolves a hundred handles. If you only need text, one
  `#evaluate_func` returning an array of strings is far cheaper.
- **A handle can go stale.** Navigate, or replace the subtree, and reads on an
  old `Node` fail. Re-query after anything that rebuilds the DOM.

`Frame#to_node(stub)` is public so `Node#at_css` can reuse that path; you can
call it if you fetched a node stub yourself through `#evaluate_func`.

## When to skip nodes entirely

Reading a list through node handles is `2n` round trips. Doing it in one
`#evaluate_func` is one:

```ruby
# 1 round trip
titles = page.evaluate_func(<<~JS)
  function() {
    return Array.from(document.querySelectorAll("h3")).map(function (h) {
      return h.textContent;
    });
  }
JS
```

Use `Node` when you need to *act* on an element or keep reading from it. Use
[`#evaluate_func`](javascript.md) when you just want data out.
