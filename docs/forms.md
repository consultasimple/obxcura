# Forms and input

Everything here is on `Node`, so start with a query.

```ruby
field = page.at_css("#username")
field.focus
field.type("guillermo")
field.value            # => "guillermo"
field.submit
```

## `#focus`

Gives the node keyboard focus, via `DOM.focus`. Returns `self`.

```ruby
page.at_css("#username").focus
```

You rarely call it directly — `#type` focuses first, because key events go to the
active element.

## `#type(*keys)`

Types text with **real key events**. Obscura implements
`Input.dispatchKeyEvent`, so the browser performs the insertion and `keydown`,
`input` and `keyup` fire exactly as they would from a keyboard. Returns `self`.

```ruby
field.type("hello")
field.type("hello", " ", "world")     # fragments are joined
```

Three things to know:

- **It appends.** Matching keyboard behaviour, typing into a control that already
  has text adds to it. Clear first if you want a replacement:

  ```ruby
  page.evaluate_func("function(s){ document.querySelector(s).value = '' }", "#username")
  field.type("replacement")
  ```

- **`change` does not fire per keystroke.** Real browsers only fire it on blur.
  If you have a listener that depended on the old behaviour, move it to `input`.

- **It costs two round trips per character.** `Input.insertText` is unimplemented
  in Obscura, so there is no bulk path. Fine for form fields — 100 characters is
  about 40ms — but 500 characters is around 0.11s and it scales linearly. To
  stuff a large body of text in, assign `value` directly and accept that no key
  events fire:

  ```ruby
  page.evaluate_func(<<~JS, "#bio", long_text)
    function(selector, text) { document.querySelector(selector).value = text; }
  JS
  ```

  That is the right trade when the page has no keystroke listeners, and the wrong
  one when it does.

## `#value`

Reads a form control's current value, or `nil`.

```ruby
field.value    # => "guillermo"
```

Use it to assert what actually landed, especially after `#type` — a field with a
mask or a `maxlength` will not hold what you sent.

## `#submit`

Submits the node's form. Works whether the node *is* the `<form>` or a control
inside one — it resolves through `.form`, then the closest `<form>` ancestor.
Returns `self`.

```ruby
page.at_css("form").submit
page.at_css("#username").submit    # same form
```

**It always uses `requestSubmit`, never `submit()`.** That matters: as of Obscura
0.1.11 the two genuinely differ. `requestSubmit` follows the interactive path —
constraint validation runs, and a cancelable `submit` event fires. `submit()`
bypasses both. There is deliberately no fallback, because falling back would
quietly skip your validation and any listener you registered.

Raises `Obxcura::ProtocolError` when the node is not a form and has no form
ancestor:

```ruby
page.at_css("h1").submit
# => Obxcura::ProtocolError: node is not a form and has no ancestor form
```

## Submitting does not wait

`#submit` returns as soon as the submission is requested. It does not block for
the resulting navigation, and Obscura stops pumping the event loop shortly after
`load` — so do not submit and then `sleep`.

Assert on something concrete instead:

```ruby
page.at_css("form").submit
page.at_css("#done")          # the marker the destination renders
```

If a submission navigates and you need the loaded document, drive it as a
navigation you control — read the form's `action`, then `page.goto` — or check
`page.current_url` to confirm where you ended up.

## A full example

```ruby
browser = Obxcura.start
begin
  page = browser.go_to("http://127.0.0.1:4567/login")

  page.at_css("#username").type("guillermo")
  page.at_css("#password").type("hunter2")
  page.at_css("form").submit

  raise "login failed" unless page.at_css("#dashboard")
  puts page.current_url
ensure
  browser.quit
end
```
