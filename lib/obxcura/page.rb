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
  # Obscura has no paint engine, so there is deliberately no screenshot API.
  #
  # @example
  #   page = browser.create_page
  #   page.goto("https://example.com")
  #   page.html                 # rendered DOM after JS
  #   page.title                # "Example Domain"
  #   page.at_css("h1").text    # => "Example Domain"
  #   page.close
  class Page
    extend Forwardable

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

    # POST via XMLHttpRequest from the page context. Obscura routes XHR but not
    # fetch, so this is the reliable POST path. All values cross as arguments,
    # never interpolated into the JS. Returns { status, ok, body } on any HTTP
    # reply (including 4xx/5xx). A transport failure — the request never reached
    # the server (blocked by CORS / private-network SSRF guard, mixed origin, or
    # a dead host) — raises ConnectionError instead of silently returning nil.
    #
    # `timeout` (seconds) bounds how long we wait for the reply. If the server
    # accepts the connection but never answers the XHR (some anti-bot endpoints
    # tarpit non-stealth clients), the wait ends with a TimeoutError that points
    # at the likely cause. Note: Obscura ignores XMLHttpRequest#timeout, so the
    # effective bound is this CDP-level one.
    #
    # @param url [String] the URL to POST to.
    # @param payload [String] the raw request body.
    # @param content_type [String] the Content-Type header value.
    # @param headers [Hash{String=>String}] extra request headers.
    # @param timeout [Integer, nil] seconds to wait for the reply.
    # @return [Hash] `{ "status" => Integer, "ok" => Boolean, "body" => String }`.
    # @raise [Obxcura::ConnectionError] if the request never reached the server.
    # @raise [Obxcura::TimeoutError] if the server accepts but never answers.
    def xhr_post(url, payload, content_type, headers, timeout: nil)
      result = evaluate_func(<<~JS, url, payload, content_type, headers, timeout:)
        function(url, payload, contentType, headers) {
          return new Promise((resolve) => {
            const x = new XMLHttpRequest();
            x.onreadystatechange = () => {
              if (x.readyState === 4) {
                resolve({ status: x.status, ok: x.status >= 200 && x.status < 300, body: x.responseText });
              }
            };
            x.onerror = () => resolve({ error: "network error or request blocked (CORS / private network / mixed origin)" });
            try {
              x.open("POST", url, true);
              x.setRequestHeader("Content-Type", contentType);
              Object.keys(headers).forEach((k) => x.setRequestHeader(k, headers[k]));
              x.send(payload);
            } catch (e) {
              resolve({ error: String(e) });
            }
          });
        }
      JS

      if result.nil? || result["error"]
        reason = result&.dig("error") || "no response (request blocked or never settled)"
        raise ConnectionError, "POST #{url} failed: #{reason}"
      end

      result
    rescue TimeoutError
      raise TimeoutError,
        "POST #{url} did not complete in time. The server accepted the connection " \
        "but never answered the XHR — likely anti-bot tarpitting. Try submitting the " \
        "real form with #type/#submit, run `obscura serve --stealth`, or pass a larger timeout:."
    end

    private

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
