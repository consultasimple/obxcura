# frozen_string_literal: true

module Obxcura
  # The browser's cookies, seen from one page: enumerable over the ones that page's
  # URL would send, and writable.
  #
  #   page.cookies                       # enumerable, scoped to the current URL
  #   page.cookies["session"]            # => { "name" => "session", ... }
  #   page.cookies.all                   # every cookie the connection holds
  #   page.cookies.set("token", "abc")
  #   page.cookies.remove("token")
  #   page.cookies.clear
  #
  # Reached through {Obxcura::Page#cookies}. Cookies are raw CDP hashes with
  # string keys — the same shape going out as coming in, so one read here can be
  # replayed into another browser.
  #
  # Every read hits the browser; nothing is cached. Two calls are two round trips.
  #
  # ## Why the scoping happens in Ruby
  #
  # CDP has a parameter for exactly this — `Network.getCookies` takes `urls:` —
  # and **Obscura ignores it**. Measured against 0.2.0: `Storage.getCookies`,
  # `Network.getCookies` with or without `urls:`, and `Network.getAllCookies` all
  # answer with the same thing, the entire jar of the connection's browser
  # context, whatever URL you ask about and whichever page's session you ask
  # from. Asking for `https://example.com/` while parked on localhost still
  # returns the localhost cookies. So {.for_url} does the matching here.
  #
  # The rules are RFC 6265 §5.1.3–5.1.4: domain-match, then path-match, then the
  # `Secure` flag, then expiry. Ports are not part of cookie scope and are ignored.
  #
  # ## Two measured behaviours worth knowing
  #
  # **The jar is the connection's, not the page's.** Obscura gives each
  # connection its own browser context, so a second `Browser` starts clean — but
  # every page on one connection shares one jar, and a page that never navigated
  # anywhere still sees all of it. {#all} is that jar; the enumerable view is the
  # slice for one URL.
  #
  # **An expired cookie stays in the jar and simply stops being sent.** So {#all}
  # can show you something the browser will never put on the wire, and the scoped
  # view drops it.
  #
  # ## One deliberate imprecision
  #
  # A cookie set with `Domain=example.com` is a *domain* cookie — the browser
  # sends it to `www.example.com` too — while one set without the attribute is
  # host-only. Chrome records the difference by storing the first as
  # `.example.com`; Obscura stores it verbatim as `example.com` (measured), so
  # the leading dot is not a reliable marker and there is nothing left to tell
  # the two apart. Domain-matching therefore applies to every entry, which can
  # include a host-only cookie on a subdomain it would not really be sent to.
  # Over-reporting beats dropping the session cookie you came for.
  class Cookies
    include Enumerable

    # Values CDP accepts for `sameSite`. Obscura takes anything and quietly
    # stores `Lax`, so this is checked here or nowhere.
    #
    # @return [Array<String>]
    SAME_SITE = %w[Strict Lax None].freeze

    # Ruby option names accepted by {#set}, mapped to their CDP spelling.
    #
    # @return [Hash{Symbol=>Symbol}]
    WRITABLE = {
      url: :url, domain: :domain, path: :path, secure: :secure,
      http_only: :httpOnly, same_site: :sameSite, expires: :expires
    }.freeze

    # The keys of a cookie hash that {#set} can send back. A read carries more
    # than a write accepts (`size`, `session`, `sourcePort`, ...), and Obscura
    # takes unknown parameters silently, so the extras are dropped here.
    #
    # @return [Array<String>]
    REPLAYABLE = %w[name value url domain path secure httpOnly sameSite expires].freeze

    # The cookies from `cookies` that the browser would attach to `url`.
    #
    # @param cookies [Array<Hash>] raw CDP cookie hashes (string keys).
    # @param url [String, nil] the URL to scope to.
    # @param now [Time] the moment to judge expiry against.
    # @return [Array<Hash>] the matching cookies, in jar order. Empty if `url`
    #   carries no host — `about:blank`, a data URI, or nothing at all.
    def self.for_url(cookies, url, now: Time.now)
      uri = parse(url)
      return [] if uri.nil? || uri.hostname.nil?

      cookies.select { |cookie| match?(cookie, uri, now) }
    end

    # @param cookie [Hash] a raw CDP cookie hash.
    # @param uri [URI::Generic] the destination, already parsed.
    # @param now [Time] the moment to judge expiry against.
    # @return [Boolean] whether the browser would send this cookie there.
    def self.match?(cookie, uri, now = Time.now)
      return false if cookie["secure"] && uri.scheme != "https"
      return false if expired?(cookie, now)

      # #hostname, not #host: the latter keeps the brackets on an IPv6 literal
      # (`[::1]`) while CDP reports the cookie domain bare (`::1`).
      domain_match?(cookie["domain"].to_s, uri.hostname) && path_match?(cookie["path"].to_s, uri.path)
    end

    # CDP reports a session cookie as `expires: -1`; anything else is epoch
    # seconds. Obscura keeps expired entries in the jar rather than sweeping
    # them, so this is what stops them being reported as live.
    def self.expired?(cookie, now = Time.now)
      expires = cookie["expires"]
      return false if expires.nil? || expires.negative?

      expires <= now.to_f
    end

    # RFC 6265 §5.1.3, with the leading dot of a domain cookie stripped first.
    def self.domain_match?(domain, host)
      domain = domain.delete_prefix(".").downcase
      host = host.downcase
      return false if domain.empty?

      host == domain || host.end_with?(".#{domain}")
    end

    # RFC 6265 §5.1.4: equal, or a prefix ending at a `/` boundary — so `/deep`
    # covers `/deep/page` but not `/deeper`.
    def self.path_match?(cookie_path, url_path)
      cookie_path = "/" if cookie_path.empty?
      url_path = "/" if url_path.nil? || url_path.empty?
      return true if cookie_path == "/" || url_path == cookie_path

      url_path.start_with?(cookie_path.end_with?("/") ? cookie_path : "#{cookie_path}/")
    end

    def self.parse(url)
      URI.parse(url.to_s)
    rescue URI::InvalidURIError
      nil
    end

    # @param page [Obxcura::Page] the page whose URL scopes the reads and whose
    #   session carries the commands.
    def initialize(page)
      @page = page
    end

    # Every cookie the connection holds, whatever domain it belongs to and
    # whether or not it is still live.
    #
    # @return [Array<Hash>] raw CDP cookie hashes.
    def all
      @page.command("Storage.getCookies")["cookies"]
    end

    # The cookies the browser would send to the page's current URL, including
    # the `HttpOnly` ones `document.cookie` cannot see — usually the point.
    #
    # @yieldparam cookie [Hash] a raw CDP cookie hash.
    # @return [Enumerator] if no block is given.
    def each(&block)
      for_url(@page.current_url).each(&block)
    end

    # The cookies that would go to some other URL instead.
    #
    # @param url [String] the URL to scope to.
    # @return [Array<Hash>] the matching cookies, in jar order.
    def for_url(url)
      self.class.for_url(all, url)
    end

    # @param name [String, Symbol] the cookie name.
    # @return [Hash, nil] the cookie the current URL would send, or nil.
    def [](name)
      wanted = name.to_s
      find { |cookie| cookie["name"] == wanted }
    end

    # @return [Integer] how many cookies the current URL would send.
    def size
      count
    end
    alias_method :length, :size

    # @return [Boolean] whether the current URL would send any cookie at all.
    def empty?
      none?
    end

    # Write a cookie.
    #
    #   page.cookies.set("token", "abc")
    #   page.cookies.set("token", "abc", path: "/app", http_only: true, expires: Time.now + 3600)
    #   page.cookies.set(saved)          # a hash read back from #[] or #all
    #
    # The browser insists on knowing where the cookie belongs — `Network.setCookie`
    # refuses with `missing required name/domain (or url)` — so with neither
    # `url:` nor `domain:` given, the page's current URL is used. On `about:blank`
    # there is nothing to fall back to and this raises before sending anything.
    #
    # Unknown options raise rather than reaching the browser, which accepts
    # anything and ignores what it does not know. `same_site:` is checked against
    # {SAME_SITE} for the same reason: an unrecognised value is stored as `Lax`
    # without a word of complaint.
    #
    # @param name_or_cookie [String, Symbol, Hash] the cookie name, or a whole
    #   cookie hash (string or symbol keys) to replay.
    # @param value [Object, nil] the cookie value, stringified. Omitted when
    #   passing a hash.
    # @param options [Hash] `url:`, `domain:`, `path:`, `secure:`, `http_only:`,
    #   `same_site:` (`"Strict"`, `"Lax"`, `"None"`), `expires:` (a `Time` or
    #   epoch seconds).
    # @return [Hash] the parameters sent, useful for logging.
    # @raise [ArgumentError] on an unknown option, a bad `same_site:`, or nowhere
    #   to attach the cookie to.
    # @raise [Obxcura::Error] if the browser reports the write failed.
    def set(name_or_cookie, value = nil, **options)
      params = name_or_cookie.is_a?(Hash) ? from_cookie(name_or_cookie) : { name: name_or_cookie.to_s, value: value.to_s }
      params = params.merge(translate(options))
      params = params.merge(url: anchor_url) unless params[:url] || params[:domain]
      validate!(params)

      result = @page.command("Network.setCookie", params)
      raise Error, "the browser refused to set cookie #{params[:name].inspect}" if result["success"] == false

      params
    end

    # Delete a cookie.
    #
    #   page.cookies.remove("session")                 # the one this URL would send
    #   page.cookies.remove("session", path: "/deep")  # a specific one
    #
    # By default this deletes whichever cookies of that name the current URL
    # would actually send, each at the exact domain and path the jar reports —
    # because `Network.deleteCookies` compares the path *exactly*. Measured: a
    # delete aimed at `/cookies` does not touch a cookie set on `/`, and one
    # aimed at `/` does not touch a cookie set on `/deep`. Naming a `domain:` or
    # `path:` yourself skips that lookup and sends what you asked for.
    #
    # @param name [String, Symbol] the cookie name.
    # @param url [String, nil] scope the lookup to this URL instead of the
    #   page's current one.
    # @param domain [String, nil] delete at this exact domain.
    # @param path [String, nil] delete at this exact path.
    # @return [Boolean] whether a cookie of that name actually went away.
    #   `false` means nothing matched — usually a path that does not line up.
    #   Deliberately narrow: the jar is shared by every page on the connection
    #   and can change underfoot, so comparing whole snapshots would report
    #   somebody else's write as this delete.
    # @raise [ArgumentError] with neither `domain:` nor anywhere to match
    #   against, exactly as {#set} refuses.
    def remove(name, url: nil, domain: nil, path: nil)
      wanted = name.to_s
      scope = domain ? url : (url || anchor_url)
      before = all
      sent = false

      if domain || path
        params = { name: wanted, url: scope, domain: domain, path: path }.compact
        @page.command("Network.deleteCookies", params)
        sent = true
      else
        self.class.for_url(before, scope)
          .select { |cookie| cookie["name"] == wanted }
          .each do |cookie|
            @page.command("Network.deleteCookies", name: wanted, domain: cookie["domain"], path: cookie["path"])
            sent = true
          end
      end

      return false unless sent

      matching(before, wanted) != matching(all, wanted)
    end

    # Drop every cookie the connection holds — not just the ones for this page.
    # Same call as {Obxcura::Browser#clear_cookies}.
    #
    # @return [void]
    def clear
      @page.command("Network.clearBrowserCookies")
      nil
    end

    # Shows the cookies the current URL would send, which costs a round trip —
    # this is a live view, so there is nothing local to print. Consoles and
    # debuggers call this implicitly, though, so a page or connection that has
    # gone away degrades into a note rather than raising out of `p page`.
    #
    # @return [String]
    def inspect
      "#<#{self.class} #{map { |cookie| "#{cookie['name']}=#{cookie['value']}" }.join(' ')}>"
    rescue Error, SystemCallError, IOError => e
      "#<#{self.class} (unavailable: #{e.message})>"
    end

    private

    # A cookie hash as read back, reduced to what a write accepts.
    def from_cookie(cookie)
      params = cookie.each_with_object({}) do |(key, value), result|
        name = key.to_s
        result[name.to_sym] = value if REPLAYABLE.include?(name)
      end
      params[:name] = params[:name].to_s if params.key?(:name)
      params[:value] = params[:value].to_s
      # -1 is CDP for "session cookie"; sending it back would be a date in 1969.
      params.delete(:expires) if params[:expires].is_a?(Numeric) && params[:expires].negative?
      params
    end

    def translate(options)
      unknown = options.keys - WRITABLE.keys
      unless unknown.empty?
        raise ArgumentError,
          "unknown cookie option#{'s' if unknown.length > 1} #{unknown.map(&:inspect).join(', ')} — " \
          "use one of #{WRITABLE.keys.join(', ')}"
      end

      options.each_with_object({}) do |(key, value), result|
        result[WRITABLE.fetch(key)] = key == :expires ? epoch(value) : value
      end
    end

    # Time, Date and DateTime all answer #to_time; anything numeric is already
    # epoch seconds. Left as-is, a Date would travel into the JSON as an object
    # and Obscura would swallow it without a word, storing a session cookie.
    def epoch(expires)
      expires.respond_to?(:to_time) ? expires.to_time.to_i : expires
    end

    # The browser will not take a cookie that belongs nowhere, and neither will
    # it delete one. Shared by #set and #remove so both refuse in the same place.
    def anchor_url
      url = @page.current_url
      return url if self.class.parse(url)&.hostname

      raise ArgumentError,
        "no url: or domain: given, and the page is at #{url.inspect} — " \
        "navigate first or say where the cookie belongs"
    end

    def validate!(params)
      if params[:name].to_s.empty?
        raise ArgumentError,
          "a cookie needs a name, got #{params[:name].inspect} — " \
          "passing nil usually means the read it came from found nothing"
      end

      same_site = params[:sameSite]
      return if same_site.nil? || SAME_SITE.include?(same_site.to_s)

      raise ArgumentError,
        "same_site: must be one of #{SAME_SITE.join(', ')}, got #{same_site.inspect} — " \
        "the browser would accept it silently and store Lax"
    end

    def matching(jar, name)
      jar.select { |cookie| cookie["name"] == name }
    end
  end
end
