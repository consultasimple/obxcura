# Running JavaScript

Three entry points, in increasing order of control.

```ruby
page.evaluate("document.title")                      # an expression
page.evaluate_func("function(a){ return a * 2 }", 21) # a function + arguments
frame.call_on(object_id, "function(){ ... }")         # bound to a specific object
```

## `#evaluate(expression, *args)`

Evaluates an expression and returns its value, JSON-decoded. Promises are
awaited.

```ruby
page.evaluate("1 + 1")                    # => 2
page.evaluate("document.title")           # => "Example Domain"
page.evaluate("[1,2,3].map(n => n * 2)")  # => [2, 4, 6]
```

With no arguments this is a single `Runtime.evaluate` — the hot path. Pass
arguments and it routes through `Runtime.callFunctionOn` instead, reachable as
`arguments[0]`, `arguments[1]`, …

```ruby
page.evaluate("arguments[0] + arguments[1]", 2, 3)    # => 5
```

**Arguments cross as real values, never interpolated into source.** That is the
whole point: a string argument cannot close a quote and inject code.

```ruby
page.evaluate("arguments[0]", "'; alert(1); //")
# => "'; alert(1); //"   — a string, not executed
```

Never build JS by interpolating Ruby into the source. Pass arguments.

## `#evaluate_func(expression, *args, timeout: nil)`

Here `expression` is the function declaration itself, called with your
arguments. Clearer than `arguments[...]` once there is more than one.

```ruby
page.evaluate_func("function(a, b) { return a + b; }", 2, 3)   # => 5

page.evaluate_func(<<~JS, "#username", "hello")
  function(selector, text) {
    const el = document.querySelector(selector);
    if (!el) return { error: "not found: " + selector };
    el.value = text;
    return el.value;
  }
JS
```

`timeout:` overrides the client's reply timeout for this one call — for work you
know is slow, rather than raising the default for everything.

## `#call_on(object_id, function_declaration, args = [], timeout: nil)`

On `Frame`. Calls a function with a specific remote object as `this`. This is
what every `Node` read is built on.

```ruby
node = page.at_css("h1")
page.frame.call_on(node.remote_object_id, "function() { return this.tagName; }")
# => "H1"
```

Use it when a wrapped `Node` method does not exist for what you need.

## Errors do not travel as exceptions

**A JavaScript `throw` does not become a Ruby exception.** In Obscura an in-page
throw is swallowed and the call returns `undefined` — so `nil` on the Ruby side,
indistinguishable from a function that legitimately returned nothing.

```ruby
page.evaluate("(function(){ throw new Error('boom') })()")   # => nil, no raise
```

This is why the gem's own JavaScript returns `{ error: ... }` sentinels and
raises from Ruby after inspecting them. Write yours the same way:

```ruby
result = page.evaluate_func(<<~JS, "#missing")
  function(selector) {
    const el = document.querySelector(selector);
    if (!el) return { error: "no element for " + selector };
    return { ok: el.textContent };
  }
JS

raise Obxcura::Error, result["error"] if result.is_a?(Hash) && result["error"]
```

`Obxcura::ProtocolError` *is* raised when CDP itself reports a problem —
`exceptionDetails` on the result, a bad command, a stale object id. It is the
in-page `throw` specifically that vanishes.

## Background work stops early

Obscura pumps the page event loop for a bounded window after `load` — measured
at roughly 400–500ms — and then stops. Timers past that never fire.

```ruby
page.evaluate("setTimeout(() => { window.done = true }, 2000)")
sleep 3
page.evaluate("window.done")    # => nil. The timer never ran.
```

So: do not wait for background JavaScript. Read what is there, or drive the page
with real input events. Anything that needs to happen must be reachable
synchronously, or awaited inside a single `#evaluate` call — where promises *are*
awaited properly.

And never leave a promise pending. A promise that never settles starves the whole
connection until the browser abandons it, which takes ~30s in 0.2.0 — see
[Browser constraints](constraints.md).
