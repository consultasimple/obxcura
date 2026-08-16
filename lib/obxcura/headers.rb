# frozen_string_literal: true

module Obxcura
  # Extra HTTP headers sent with requests, as a small mutable collection.
  #
  #   page.headers.set("X-Token" => "abc")   # replaces the whole table
  #   page.headers.add("Accept" => "*/*")    # merges into it
  #   page.headers["X-Token"]                # => "abc"
  #   page.headers.delete("X-Token")
  #   page.headers.clear
  #
  # Reached through {Obxcura::Page#headers}.
  #
  # ## Why the state lives here
  #
  # CDP is write-only about this: `Network.setExtraHTTPHeaders` sets the table and
  # there is no matching getter — Obscura answers `Network.getExtraHTTPHeaders`
  # with `Unknown Network method`. So {#get} reports what *this object* last sent,
  # which is the only readable record that exists. Change the headers through
  # another route — a raw {Page#command}, a second `Headers` on another page — and
  # this object will not know.
  #
  # ## Two measured behaviours worth knowing
  #
  # **The scope is the connection, not the page.** The API hangs off `Page`
  # because that is the only session the command works from — sent without a
  # session it is accepted and silently does nothing — but Obscura applies one
  # table per connection. Setting headers on one page changes them for *every*
  # page on that browser, and the last write wins. Two pages cannot carry
  # different headers.
  #
  # **They cover navigation only.** Obscura attaches extra headers to the
  # document and its subresources, never to requests started from script. A
  # {Page#post} — or any in-page `fetch`/`XMLHttpRequest` — does not carry them,
  # which is why `#post` takes its own `headers` argument.
  #
  # Header names are case-insensitive per RFC 9110, so writing `x-token` after
  # `X-Token` replaces it rather than sending both. Names and values are sent as
  # strings, since that is what CDP accepts.
  class Headers
    # @param page [Obxcura::Page] the page whose session carries the command.
    def initialize(page)
      @page = page
      @headers = {}
    end

    # The headers this object last sent.
    #
    # @return [Hash{String=>String}] a copy, safe to mutate.
    def get
      @headers.dup
    end
    alias_method :to_h, :get

    # Replace every header with `headers`. Mirrors what the browser does: the
    # table is overwritten, not merged.
    #
    # @param headers [Hash] names and values, stringified on the way in.
    # @return [Hash{String=>String}] the resulting table.
    def set(headers)
      @headers = normalize(headers)
      apply
    end

    # Merge `headers` into the current table, replacing only the names given.
    #
    # @param headers [Hash] names and values.
    # @return [Hash{String=>String}] the resulting table.
    def add(headers)
      normalize(headers).each { |name, value| store(name, value) }
      apply
    end

    # Remove every header.
    #
    # @return [Hash] the now-empty table.
    def clear
      @headers = {}
      apply
    end

    # @param name [String, Symbol] header name, matched case-insensitively.
    # @return [String, nil] the value, or nil if unset.
    def [](name)
      _, value = entry(name)
      value
    end

    # Set a single header, leaving the rest in place.
    #
    # @param name [String, Symbol] header name.
    # @param value [Object] value, stringified.
    # @return [Object] `value`, as assignment in Ruby always does.
    def []=(name, value)
      store(name.to_s, value.to_s)
      apply
      value
    end

    # Remove a single header.
    #
    # @param name [String, Symbol] header name, matched case-insensitively.
    # @return [String, nil] the removed value, or nil if it was not set.
    def delete(name)
      key, value = entry(name)
      return nil if key.nil?

      @headers.delete(key)
      apply
      value
    end

    # @param name [String, Symbol] header name, matched case-insensitively.
    # @return [Boolean] whether the header is set.
    def key?(name)
      !entry(name).first.nil?
    end
    alias_method :include?, :key?

    # @return [Boolean] whether any header is set.
    def empty?
      @headers.empty?
    end

    # @return [Integer] how many headers are set.
    def size
      @headers.size
    end
    alias_method :length, :size

    # @return [String]
    def inspect
      "#<#{self.class} #{@headers.inspect}>"
    end

    private

    # Writes go through here so a name that differs only in case replaces the
    # existing entry instead of sitting beside it — two spellings of one header
    # is always a bug, never an intent.
    def store(name, value)
      existing, = entry(name)
      @headers.delete(existing) if existing

      @headers[name] = value
    end

    def entry(name)
      wanted = name.to_s.downcase
      @headers.find { |key, _| key.downcase == wanted } || [ nil, nil ]
    end

    def normalize(headers)
      headers.each_with_object({}) do |(name, value), result|
        result[name.to_s] = value.to_s
      end
    end

    def apply
      @page.command("Network.setExtraHTTPHeaders", headers: @headers)
      get
    end
  end
end
