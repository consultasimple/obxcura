# frozen_string_literal: true

require "forwardable"

module Obxcura
  # The entry point. Owns one Client (one connection) and the pages opened on it.
  #
  #   browser = Obxcura::Browser.new
  #   page    = browser.create_page
  #   browser.quit
  #
  # Assumes a running `obscura serve` (default 127.0.0.1:9222). Pass host:/port:
  # to point elsewhere.
  class Browser
    extend Forwardable

    # @return [String] default host for `obscura serve`.
    DEFAULT_HOST = "127.0.0.1"
    # @return [Integer] default CDP port for `obscura serve`.
    DEFAULT_PORT = 9222
    # The only URL a target may safely be created at; see {#create_page}.
    #
    # @return [String]
    BLANK_PAGE = "about:blank"

    # @return [Obxcura::Client] the underlying CDP transport.
    # @return [Array<Obxcura::Page>] the pages currently open.
    # @return [String] the browser host.
    # @return [Integer] the browser port.
    attr_reader :client, :pages, :host, :port

    delegate %i[command] => :client

    # Connect to a running `obscura serve`.
    #
    # @param host [String] host the browser listens on.
    # @param port [Integer] CDP port the browser listens on.
    # @param timeout [Integer] default seconds to wait for CDP replies.
    # @raise [Obxcura::ConnectionError] if the browser can't be reached.
    def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT, timeout: Client::DEFAULT_TIMEOUT)
      @host = host
      @port = port
      @timeout = timeout
      @pages = []
      @client = Client.new(browser_ws_url, timeout: @timeout)
    end

    # Open a fresh page (a CDP target) and attach to it. With a `url`, the page
    # is navigated there and the call blocks until its load event fires.
    #
    # The target is always created blank and then navigated, never opened at
    # `url` directly. Handing a URL to `Target.createTarget` works exactly once:
    # the *second* such call on a connection kills `obscura serve` outright —
    # every command after it fails with `connection closed: end of file
    # reached`, and the process is gone, not just the socket. Measured on 0.2.0
    # and deterministic, whatever the URLs are; two blank targets are fine, and
    # so is any amount of navigation. Since the parameter cannot be honoured
    # literally without handing callers a way to kill the browser, it is honoured
    # by navigating.
    #
    # @param url [String] URL to open the page at (defaults to a blank page).
    # @return [Obxcura::Page] the new, tracked page.
    def create_page(url = BLANK_PAGE)
      target_id = command("Target.createTarget", { url: BLANK_PAGE })["targetId"]
      session_id = command("Target.attachToTarget", { targetId: target_id, flatten: true })["sessionId"]

      page = Page.new(self, target_id: target_id, session_id: session_id)
      @pages << page
      page.goto(url) unless url == BLANK_PAGE
      page
    end

    # Open a page and navigate to `url` in one call — the expressive name for
    # {#create_page} with a URL.
    #
    # @param url [String] URL to navigate to.
    # @return [Obxcura::Page] the navigated page (load event fired).
    def go_to(url)
      create_page(url)
    end
    alias goto go_to

    # Every target the browser knows about (pages, workers, ...).
    #
    # @return [Array<Hash>] raw CDP `TargetInfo` hashes.
    def targets
      command("Target.getTargets")["targetInfos"]
    end

    # The browser's `/json/version` metadata (product, protocol, ws endpoint).
    #
    # @return [Hash] the decoded JSON version document.
    def version
      uri = URI("http://#{@host}:#{@port}/json/version")
      JSON.parse(Net::HTTP.get(uri))
    end

    # Drop every cookie held on this connection.
    #
    # Since Obscura 0.1.11 each connection owns its own browser context, so cookies
    # no longer leak between `Browser` instances and this is only about resetting
    # state *within* one connection — between logical sessions on the same socket,
    # say. `obscura serve` is still long-lived and {#quit} only drops the socket, so
    # a fresh `Browser` is the other way to get a clean jar.
    #
    # @return [void]
    def clear_cookies
      command("Network.clearBrowserCookies")
      nil
    end

    # Stop tracking a page. Called by {Obxcura::Page#close}.
    #
    # @param page [Obxcura::Page] the page to forget.
    # @return [Obxcura::Page, nil] the removed page, or nil if unknown.
    def remove_page(page)
      @pages.delete(page)
    end

    # Close every page, then drop the connection. Aliased as `quit`.
    #
    # @return [void]
    def close
      @pages.dup.each(&:close)
      client.close
    end
    alias quit close

    private

    def browser_ws_url
      info = version
      info["webSocketDebuggerUrl"] ||
        raise(ConnectionError, "No browser endpoint at #{@host}:#{@port}")
    rescue SystemCallError, SocketError => e
      raise ConnectionError,
        "Could not reach Obscura at #{@host}:#{@port} (#{e.message}). Is it running? Start it with: obscura serve"
    end
  end
end
