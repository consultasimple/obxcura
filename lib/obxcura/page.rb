# frozen_string_literal: true

require "forwardable"

module Obxcura
  # A single page/tab: a CDP target with its own attached session. Created via
  # {Obxcura::Browser#create_page} — you rarely instantiate this directly.
  #
  # Page owns the CDP session, navigation, in-page POSTs and lifecycle. Reading
  # the DOM and executing JS belong to its main {Frame} (see {Frame::DOM} and
  # {Frame::Runtime}), and Page delegates those (`#evaluate`, `#html`, `#title`,
  # `#at_css`, ...).
  #
  # @example
  #   page = browser.create_page
  #   page.goto("https://example.com")
  #   page.html                 # rendered DOM after JS
  #   page.title                # "Example Domain"
  #   page.at_css("h1").text    # => "Example Domain"
  #   page.screenshot(path: "example.png")
  #   page.close
  class Page
    extend Forwardable

    # Seconds of slack given to the CDP reply beyond a {#post} timeout, so the
    # in-page abort is what surfaces rather than the transport giving up first.
    #
    # @return [Integer]
    TIMEOUT_HEADROOM = 5

    # Image formats Obscura's render engine will encode.
    #
    # @return [Array<Symbol>]
    SCREENSHOT_FORMATS = %i[png jpeg webp].freeze

    # File extensions mapped to a {SCREENSHOT_FORMATS} entry, so `path:` alone
    # can pick the encoder.
    #
    # @return [Hash{String=>Symbol}]
    SCREENSHOT_EXTENSIONS = {
      ".png" => :png, ".jpg" => :jpeg, ".jpeg" => :jpeg, ".webp" => :webp
    }.freeze

    # @return [String] the CDP target id backing this page.
    # @return [String] the CDP session id attached to the target.
    # @return [Obxcura::Client] the shared CDP transport.
    # @return [Obxcura::Frame] the page's main frame.
    attr_reader :target_id, :session_id, :client, :frame

    # Delegated to the main {Frame}: `#evaluate`, `#evaluate_func`,
    # `#current_url`, `#title`, `#html`, `#body`, `#at_css`, `#css`.
    def_delegators :frame, :evaluate, :evaluate_func, :current_url, :title, :html, :body, :at_css, :css

    # @param browser [Obxcura::Browser] the owning browser.
    # @param target_id [String] the CDP target id.
    # @param session_id [String] the CDP session attached to the target.
    def initialize(browser, target_id:, session_id:)
      @browser = browser
      @client = browser.client
      @target_id = target_id
      @session_id = session_id
      @frame = Frame.new(target_id, self)
      @load_queue = Queue.new
      @network_log = []
      @network_mutex = Mutex.new

      @client.subscribe(@session_id) { |method, params| dispatch_event(method, params) }
      command("Network.enable")
    end

    # Requests this page issued, oldest first, as
    # `{ url:, request_id:, finished: }`.
    #
    # Scope is deliberately narrow: Obscura emits Network events for requests the
    # *navigation* drives (the document and its subresources), but not for ones
    # started from script. A {#post} — or any in-page `fetch`/`XMLHttpRequest` —
    # therefore never shows up here. Verified against Obscura 0.1.11: enabling the
    # Network domain and issuing a scripted POST produces no events at all.
    #
    # @return [Array<Hash>] a snapshot of the log, safe to iterate.
    def network_log
      @network_mutex.synchronize { @network_log.map(&:dup) }
    end

    # Navigate to `url` and block until the page's load event fires. Aliased as
    # `go_to`.
    #
    # @param url [String] the URL to navigate to.
    # @return [self]
    def goto(url)
      @load_queue = Queue.new
      command("Page.navigate", url: url)
      wait_for_load
      self
    end
    alias_method :go_to, :goto

    # Close this page's target and stop listening for its events.
    #
    # @return [Obxcura::Page, nil] the page, removed from the browser.
    def close
      @client.unsubscribe(@session_id)
      # @client.command("Network.clearBrowserCookies", { targetId: @target_id })
      @client.command("Target.closeTarget", { targetId: @target_id })
    rescue ProtocolError
      # Target already gone — nothing to do.
    ensure
      @browser.remove_page(self)
    end

    # Drop the underlying WebSocket connection (affects the whole browser).
    #
    # @return [void]
    def close_connection
      @client.close
    end

    # Reload the page and block until it loads again. Aliased as `reload`.
    #
    # @return [Hash] the CDP `Page.reload` result.
    def refresh
      command("Page.reload")
      wait_for_load
    end
    alias_method :reload, :refresh

    # @return [Array<Hash>] the page's cookies as CDP cookie hashes.
    def cookies
      command("Storage.getCookies")["cookies"]
    end

    # Send a CDP command scoped to this page's session.
    #
    # @param method [String] the CDP method name.
    # @param params [Hash] the method parameters.
    # @return [Hash] the command's `result` object.
    def command(method, params = {})
      @client.command(method, params, session_id: @session_id)
    end

    # POST from the page context via `fetch`. All values cross as arguments, never
    # interpolated into the JS. Returns { status, ok, body } on any HTTP reply
    # (including 4xx/5xx). A transport failure — the request never reached the
    # server (blocked by CORS / private-network SSRF guard, mixed origin, or a
    # dead host) — raises ConnectionError instead of silently returning nil.
    #
    # `timeout` (seconds) is enforced in the page by racing the fetch against a
    # timer, so a server that accepts the connection and never answers (some
    # anti-bot endpoints tarpit non-stealth clients) fails in roughly `timeout`
    # seconds instead of {Client::DEFAULT_TIMEOUT}. The CDP reply gets a little
    # headroom past that so the in-page result is what we observe.
    #
    # The race is deliberate, and not the obvious `AbortSignal.timeout`. Obscura
    # does accept an abort signal, but when the abort actually fires, the fetch
    # rejection is swallowed and the call returns `undefined` — the same
    # in-page-throws-vanish behaviour that makes {Frame::Runtime} use `{ error: }`
    # sentinels. A rejection can't carry the reason across, so a resolved value
    # has to. We still abort the underlying request once the timer wins, purely so
    # it stops occupying the connection.
    #
    # Requests made here do not appear in {#network_log}; see that method.
    #
    # @param url [String] the URL to POST to.
    # @param payload [String] the raw request body.
    # @param content_type [String] the Content-Type header value.
    # @param headers [Hash{String=>String}] extra request headers.
    # @param timeout [Integer, nil] seconds to allow before giving up.
    # @return [Hash] `{ "status" => Integer, "ok" => Boolean, "body" => String }`.
    # @raise [Obxcura::ConnectionError] if the request never reached the server.
    # @raise [Obxcura::TimeoutError] if the server accepts but never answers.
    def post(url, payload, content_type, headers, timeout: nil)
      timeout_ms = timeout && (timeout * 1000).to_i
      result = evaluate_func(<<~JS, url, payload, content_type, headers, timeout_ms, timeout: timeout && timeout + TIMEOUT_HEADROOM)
        function(url, payload, contentType, headers, timeoutMs) {
          const controller = timeoutMs ? new AbortController() : null;
          const init = {
            method: "POST",
            headers: Object.assign({ "Content-Type": contentType }, headers),
            body: payload
          };
          if (controller) init.signal = controller.signal;

          let timer = null;
          const request = fetch(url, init)
            .then((r) => r.text().then((body) => ({ status: r.status, ok: r.ok, body: body })))
            .catch((e) => ({ error: String(e) }))
            .then((outcome) => { if (timer) clearTimeout(timer); return outcome; });

          if (!timeoutMs) return request;

          return Promise.race([
            request,
            new Promise((resolve) => {
              timer = setTimeout(() => {
                if (controller) controller.abort();
                resolve({ timeout: true });
              }, timeoutMs);
            })
          ]);
        }
      JS

      raise TimeoutError, timeout_message(url) if result.is_a?(Hash) && result["timeout"]

      if result.nil? || result["error"]
        reason = result&.dig("error") || "no response (request blocked or never settled)"
        raise ConnectionError, "POST #{url} failed: #{reason}"
      end

      result
    rescue TimeoutError
      raise TimeoutError, timeout_message(url)
    end
    # @deprecated Renamed to {#post} once Obscura started routing `fetch`.
    alias_method :xhr_post, :post

    # Capture the page as an image.
    #
    # Obscura gained a paint engine in 0.2.0, so this is real rasterisation
    # rather than a serialised DOM. It needs a build carrying the render
    # feature: the `-no-render` archives of the *same version* refuse
    # `Page.captureScreenshot`, and that refusal is re-raised here as an
    # {Obxcura::Error} naming the fix rather than a bare {ProtocolError}.
    #
    # Returns the raw image bytes (BINARY encoding). Base64 is a transport
    # detail of CDP and is decoded here, so callers get something they can write
    # to disk or hand to an image library directly. With `path:` the bytes are
    # written for you and the path comes back instead.
    #
    # @example Whole document, not just the viewport
    #   page.screenshot(path: "full.png", full_page: true)
    #
    # @example A region, at twice the pixel density
    #   page.screenshot(clip: { x: 0, y: 0, width: 300, height: 200, scale: 2 })
    #
    # @param path [String, nil] write the image here and return this path.
    # @param format [Symbol, String, nil] `:png`, `:jpeg` or `:webp`. Defaults to
    #   the format implied by `path`'s extension, then to `:png`.
    # @param quality [Integer, nil] 0..100, `:jpeg` only. Rejected for `:png`,
    #   which ignores it, and for `:webp`, whose Obscura encoder is lossless and
    #   refuses the parameter outright.
    # @param full_page [Boolean] capture the whole document rather than the
    #   viewport. Mutually exclusive with `clip`.
    # @param clip [Hash, nil] region to capture: `x:`, `y:`, `width:`, `height:`
    #   and an optional `scale:` (default 1).
    # @return [String] the image bytes, or `path` when one was given.
    # @raise [ArgumentError] on an unsupported format or contradictory options,
    #   before any CDP round trip.
    # @raise [Obxcura::Error] if the browser has no render feature.
    def screenshot(path: nil, format: nil, quality: nil, full_page: false, clip: nil)
      format = resolve_screenshot_format(format, path)
      validate_screenshot!(format, quality, full_page, clip)

      params = { format: format.to_s }
      params[:quality] = quality if quality
      params[:captureBeyondViewport] = true if full_page
      params[:clip] = normalize_clip(clip) if clip

      image = decode_image(command("Page.captureScreenshot", params)["data"])
      return image unless path

      File.binwrite(path, image)
      path
    rescue ProtocolError => e
      raise unless e.message.include?("render feature")

      raise Error, "This Obscura build has no render engine, so it cannot take screenshots. " \
        "Install the unsuffixed release asset (the `-no-render` ones omit it)."
    end

    private

    def resolve_screenshot_format(format, path)
      return format.to_sym if format
      return :png unless path

      SCREENSHOT_EXTENSIONS.fetch(File.extname(path).downcase, :png)
    end

    def validate_screenshot!(format, quality, full_page, clip)
      unless SCREENSHOT_FORMATS.include?(format)
        raise ArgumentError,
          "unsupported screenshot format #{format.inspect} — use one of #{SCREENSHOT_FORMATS.join(', ')}"
      end

      raise ArgumentError, "full_page and clip contradict each other — pass one or the other" if full_page && clip

      return if quality.nil?

      unless format == :jpeg
        raise ArgumentError,
          "quality applies to :jpeg only — :png ignores it, and Obscura's :webp encoder is lossless"
      end

      raise ArgumentError, "quality must be between 0 and 100, got #{quality}" unless (0..100).cover?(quality)
    end

    def normalize_clip(clip)
      width = clip[:width] || clip["width"]
      height = clip[:height] || clip["height"]
      raise ArgumentError, "clip needs both width and height" unless width && height

      {
        x: clip[:x] || clip["x"] || 0,
        y: clip[:y] || clip["y"] || 0,
        width: width,
        height: height,
        scale: clip[:scale] || clip["scale"] || 1
      }
    end

    # CDP hands images back as base64. `unpack1("m")` decodes leniently and
    # returns BINARY, and — unlike the base64 library — needs no require, which
    # matters since base64 left the default gems in Ruby 3.4.
    def decode_image(data)
      data.to_s.unpack1("m")
    end

    def timeout_message(url)
      "POST #{url} did not complete in time. The server accepted the connection " \
        "but never answered — likely anti-bot tarpitting. Try submitting the real " \
        "form with #type/#submit, run `obscura serve --stealth`, or pass a larger timeout:."
    end

    def dispatch_event(method, params)
      case method
      when "Page.loadEventFired"
        @load_queue.push(true)
      when "Network.responseReceived"
        @network_mutex.synchronize do
          @network_log << { url: params.dig("response", "url"), request_id: params["requestId"], finished: false }
        end
      when "Network.loadingFinished"
        @network_mutex.synchronize do
          entry = @network_log.find { |e| e[:request_id] == params["requestId"] }
          entry[:finished] = true if entry
        end
      end
    end

    def wait_for_load
      Timeout.timeout(Client::DEFAULT_TIMEOUT, TimeoutError, "Page load timed out") { @load_queue.pop }
    end
  end
end
