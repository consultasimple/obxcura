# Obxcura documentation

Reference for the whole public API, one page per area. Everything here is
verified against a real Obscura binary — where the browser's behaviour is
surprising, the page says so rather than describing what *ought* to happen.

Start with the [README](../README.md) to install and get a page on screen.

## Guides

| Page | Covers |
|---|---|
| [Connecting](connecting.md) | `Obxcura.start`, `Browser.new`, ports, timeouts, shutdown |
| [Pages](pages.md) | `#goto`, `#refresh`, `#close`, page lifecycle, raw `#command` |
| [Reading content](content.md) | `#html`, `#title`, `#current_url` |
| [Querying the DOM](dom.md) | `#at_css`, `#css`, and everything on `Node` |
| [Running JavaScript](javascript.md) | `#evaluate`, `#evaluate_func`, `#call_on` |
| [Forms and input](forms.md) | `#focus`, `#type`, `#submit`, `#value` |
| [HTTP from the page](http.md) | `#post`, `#network_log` |
| [Cookies](cookies.md) | `#cookies` — read, set, remove, replay a session |
| [Headers](headers.md) | `#headers` — reading and setting extra HTTP headers |
| [Screenshots](screenshots.md) | `#screenshot` and every option it takes |
| [PDF](pdf.md) | `#pdf` and every option it takes |
| [Errors](errors.md) | The exception hierarchy and what actually raises what |
| [Browser constraints](constraints.md) | Obscura limits that shape this API |

## The whole surface at a glance

```ruby
Obxcura.start(**opts)                # => Browser
Obxcura::VERSION
```

**`Obxcura::Browser`** — [Connecting](connecting.md)

```ruby
Browser.new(host:, port:, timeout:)
#create_page(url = "about:blank")  #go_to(url) / #goto  #targets  #version
#clear_cookies  #remove_page(page)  #close / #quit  #command
# readers: #client #pages #host #port
```

**`Obxcura::Page`** — [Pages](pages.md)

```ruby
#goto(url) / #go_to        #refresh / #reload      #close    #close_connection
#html / #body  #title  #current_url                          # -> Frame
#at_css(sel)   #css(sel)                                     # -> Node(s)
#evaluate(expr, *args)     #evaluate_func(fn, *args, timeout:)
#post(url, payload, content_type, headers, timeout:)         # alias #xhr_post
#screenshot(path:, format:, quality:, full_page:, clip:)
#pdf(path:, landscape:, print_background:, scale:, paper:,
     paper_width:, paper_height:, margin:, page_ranges:)
#headers                                                     # -> Headers
#cookies                                                     # -> Cookies
#network_log   #command(method, params)
# readers: #frame #target_id #session_id #client
```

**`Obxcura::Cookies`** (from `page.cookies`) — [Cookies](cookies.md)

```ruby
#all   #each / Enumerable   #[](name)   #for_url(url)   #size   #empty?
#set(name, value, url:, domain:, path:, secure:, http_only:, same_site:, expires:)
#set(cookie_hash)          #remove(name, url:, domain:, path:)   #clear
```

**`Obxcura::Headers`** (from `page.headers`) — [Headers](headers.md)

```ruby
#get / #to_h  #set(hash)  #add(hash)  #clear
#[](name)  #[]=(name, value)  #delete(name)  #key?  #empty?  #size
```

**`Obxcura::Node`** — [Querying the DOM](dom.md), [Forms](forms.md)

```ruby
#text  #value  #[](name) / #attribute  #outer_html  #at_css(sel)
#focus  #type(*keys)  #submit
# reader: #remote_object_id
```

**`Obxcura::Frame`** — [Running JavaScript](javascript.md)

```ruby
#evaluate  #evaluate_func  #call_on(object_id, fn, args, timeout:)
#current_url  #title  #html / #body  #at_css  #css  #to_node(stub)
#url
# reader: #page
```

**`Obxcura::Client`** — the CDP transport, if you need it directly

```ruby
#command(method, params, session_id:, timeout:)
#subscribe(session_id, &block)   #unsubscribe(session_id)
#close  #closing?  #url
# constants: DEFAULT_TIMEOUT (30) MAX_MESSAGE_SIZE (64 MiB) READ_CHUNK (64 KiB)
```
