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

    # Open a fresh page (a CDP target) and attach to it.
    #
    # @param url [String] URL to open the target at (defaults to a blank page).
    # @return [Obxcura::Page] the new, tracked page.
    def create_page(url = "about:blank")
      target_id = command("Target.createTarget", { url: url })["targetId"]
      session_id = command("Target.attachToTarget", { targetId: target_id, flatten: true })["sessionId"]

      page = Page.new(self, target_id: target_id, session_id: session_id)
      @pages << page
      page
    end

    # Open a page and navigate to `url` in one call.
    #
    # Navigates from a blank target rather than passing the URL straight to
    # Target.createTarget: creating two URL-loaded targets and then evaluating
    # crashes `obscura serve` (connection closed: end of file reached).
    #
    # @param url [String] URL to navigate to.
    # @return [Obxcura::Page] the navigated page (load event fired).
    def go_to(url)
      create_page.goto(url)
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
