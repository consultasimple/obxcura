# frozen_string_literal: true

# Obxcura — a small Ruby API for driving an Obscura browser
# (h4ckf0r0day/obscura) over the Chrome DevTools Protocol.
#
# Obscura speaks CDP over a WebSocket, just like headless Chrome. The shape is
# simple: a Browser owns one connection, and each Page is a target with its own
# attached session. One connection, many pages.
#
#   require "obxcura"
#
#   browser = Obxcura::Browser.new         # connects to a running `obscura serve`
#   page    = browser.create_page
#   page.goto("https://www.google.com")
#   puts page.html                         # rendered DOM (post-JS)
#   browser.quit
#
# Start the browser first (defaults to port 9222):
#   obscura serve
#
# nokogiri is optional — only needed for page.dom / at_css / css.

require "json"
require "net/http"
require "uri"
require "timeout"

require_relative "obxcura/version"

# Top-level namespace for the gem: a small Ruby client that drives an Obscura
# headless browser over the Chrome DevTools Protocol. See the file header above
# for the big picture; start from {Obxcura.start} or {Obxcura::Browser}.
module Obxcura
  # Base class for every error the gem raises, so callers can rescue the whole
  # family with `rescue Obxcura::Error`.
  class Error < StandardError; end

  # Raised when a CDP command (or the initial connect) does not answer in time.
  class TimeoutError < Error; end

  # Raised when Obscura returns a protocol-level error, or JS throws during evaluate.
  class ProtocolError < Error; end

  # Raised when the browser endpoint can't be reached at all (nothing listening, etc).
  class ConnectionError < Error; end

  # Connect to a running `obscura serve` and return a Browser.
  #
  # @param options [Hash] forwarded to {Obxcura::Browser#initialize}
  #   (`:host`, `:port`, `:timeout`).
  # @return [Obxcura::Browser] a connected browser.
  # @raise [Obxcura::ConnectionError] if no browser is listening.
  # @example
  #   browser = Obxcura.start(port: 9222)
  #   page    = browser.go_to("https://example.com")
  #   browser.quit
  def self.start(**options)
    Browser.new(**options)
  end
end

require_relative "obxcura/client"
require_relative "obxcura/node"
require_relative "obxcura/frame"
require_relative "obxcura/browser"
require_relative "obxcura/page"
