# frozen_string_literal: true

RSpec.describe Obxcura::Cookies do
  def cookie(overrides = {})
    {
      "name" => "session", "value" => "abc123", "domain" => "example.com",
      "path" => "/", "secure" => false, "httpOnly" => false
    }.merge(overrides)
  end

  def names(cookies, url)
    described_class.for_url(cookies, url).map { |c| c["name"] }
  end

  describe ".for_url" do
    describe "domain matching" do
      it "keeps a cookie whose domain is the host" do
        expect(names([ cookie ], "http://example.com/")).to eq([ "session" ])
      end

      it "drops a cookie belonging to another host" do
        expect(names([ cookie("domain" => "other.test") ], "http://example.com/")).to be_empty
      end

      it "matches subdomains of a dotted domain, as the browser does" do
        jar = [ cookie("domain" => ".example.com") ]

        expect(names(jar, "http://www.example.com/")).to eq([ "session" ])
      end

      # Obscura stores `Domain=example.com` verbatim rather than normalising it
      # to `.example.com`, so a dot is not a reliable marker of a domain cookie
      # and every entry gets domain-matched.
      it "matches subdomains of an undotted domain too" do
        expect(names([ cookie ], "http://www.example.com/")).to eq([ "session" ])
      end

      it "only matches on a label boundary, never a bare suffix" do
        expect(names([ cookie ], "http://notexample.com/")).to be_empty
      end

      it "ignores the port, which cookies do not scope on" do
        expect(names([ cookie ], "http://example.com:8080/")).to eq([ "session" ])
      end

      # URI#host keeps the brackets on an IPv6 literal while the jar reports the
      # address bare, so matching has to go through #hostname.
      it "matches an IPv6 literal host, brackets and all" do
        jar = [ cookie("domain" => "::1") ]

        expect(names(jar, "http://[::1]:9222/")).to eq([ "session" ])
      end

      it "compares hosts case-insensitively" do
        expect(names([ cookie("domain" => "EXAMPLE.com") ], "http://Example.COM/")).to eq([ "session" ])
      end
    end

    describe "path matching" do
      it "sends a root cookie to every path" do
        expect(names([ cookie ], "http://example.com/deep/page")).to eq([ "session" ])
      end

      it "sends a scoped cookie to its own path" do
        jar = [ cookie("path" => "/deep") ]

        expect(names(jar, "http://example.com/deep")).to eq([ "session" ])
      end

      it "sends a scoped cookie to paths below it" do
        jar = [ cookie("path" => "/deep") ]

        expect(names(jar, "http://example.com/deep/page")).to eq([ "session" ])
      end

      it "withholds a scoped cookie from a path outside it" do
        jar = [ cookie("path" => "/deep") ]

        expect(names(jar, "http://example.com/")).to be_empty
      end

      it "does not treat a prefix as a path segment" do
        jar = [ cookie("path" => "/deep") ]

        expect(names(jar, "http://example.com/deeper")).to be_empty
      end

      it "treats a URL with no path as the root" do
        expect(names([ cookie ], "http://example.com")).to eq([ "session" ])
      end

      it "ignores the query string" do
        jar = [ cookie("path" => "/deep") ]

        expect(names(jar, "http://example.com/deep?q=1")).to eq([ "session" ])
      end
    end

    describe "the secure flag" do
      it "withholds a secure cookie from an insecure URL" do
        expect(names([ cookie("secure" => true) ], "http://example.com/")).to be_empty
      end

      it "sends a secure cookie over https" do
        expect(names([ cookie("secure" => true) ], "https://example.com/")).to eq([ "session" ])
      end

      it "sends an insecure cookie over https, which is allowed" do
        expect(names([ cookie ], "https://example.com/")).to eq([ "session" ])
      end
    end

    describe "expiry" do
      # Measured: Obscura keeps an expired cookie in the jar and simply stops
      # sending it. Reporting it would make #cookies lie about the request.
      it "drops a cookie whose expiry has passed" do
        jar = [ cookie("expires" => Time.now.to_i - 60) ]

        expect(described_class.for_url(jar, "http://example.com/")).to be_empty
      end

      it "keeps one that has not expired yet" do
        jar = [ cookie("expires" => Time.now.to_i + 600) ]

        expect(names(jar, "http://example.com/")).to eq([ "session" ])
      end

      it "keeps a session cookie, which CDP reports as expires -1" do
        expect(names([ cookie("expires" => -1) ], "http://example.com/")).to eq([ "session" ])
      end
    end

    describe "URLs with nothing to match against" do
      it "returns nothing for about:blank" do
        expect(described_class.for_url([ cookie ], "about:blank")).to eq([])
      end

      it "returns nothing for an unparseable URL" do
        expect(described_class.for_url([ cookie ], "http://[bad")).to eq([])
      end

      it "returns nothing for nil" do
        expect(described_class.for_url([ cookie ], nil)).to eq([])
      end
    end

    it "returns the cookie hashes untouched, in jar order" do
      jar = [ cookie("name" => "a"), cookie("name" => "b", "domain" => "other.test"), cookie("name" => "c") ]

      expect(described_class.for_url(jar, "http://example.com/")).to eq([ jar[0], jar[2] ])
    end
  end

  describe "the collection" do
    # A stand-in for Page: records what would go on the wire and answers reads
    # from a canned jar, so the bookkeeping can be tested without a browser.
    let(:page) do
      Class.new do
        attr_reader :sent
        attr_accessor :jar, :current_url

        # `drift` mimics the jar changing underfoot — another page on the
        # connection writing, or a response carrying Set-Cookie mid-call.
        attr_accessor :drift, :dead

        def initialize
          @sent = []
          @jar = []
          @drift = false
          @dead = false
          @current_url = "https://example.com/app"
        end

        def command(method, params = {})
          raise Obxcura::ProtocolError, "connection closed: end of file reached" if @dead

          @sent << [ method, params ]
          @jar += [ { "name" => "drifted#{@sent.length}", "value" => "1",
                      "domain" => "example.com", "path" => "/" } ] if @drift
          { "cookies" => @jar, "success" => true }
        end

        def last_params = @sent.last&.last
        def methods_sent = @sent.map(&:first)
      end.new
    end

    subject(:cookies) { described_class.new(page) }

    describe "reading" do
      it "hands back the whole jar with #all" do
        page.jar = [ cookie, cookie("name" => "other", "domain" => "elsewhere.test") ]

        expect(cookies.all.length).to eq(2)
        expect(page.methods_sent).to eq([ "Storage.getCookies" ])
      end

      it "enumerates only what the current URL would send" do
        page.jar = [ cookie, cookie("name" => "other", "domain" => "elsewhere.test") ]

        expect(cookies.map { |c| c["name"] }).to eq([ "session" ])
      end

      it "finds one by name with #[]" do
        page.jar = [ cookie ]

        expect(cookies["session"]["value"]).to eq("abc123")
      end

      it "returns nil from #[] for a cookie the current URL would not get" do
        page.jar = [ cookie("domain" => "elsewhere.test") ]

        expect(cookies["session"]).to be_nil
      end

      it "counts and tests emptiness against the scoped view" do
        page.jar = [ cookie, cookie("name" => "other", "domain" => "elsewhere.test") ]

        expect(cookies.size).to eq(1)
        expect(cookies).not_to be_empty
      end

      it "scopes somewhere else with #for_url" do
        page.jar = [ cookie("domain" => "elsewhere.test") ]

        expect(cookies.for_url("https://elsewhere.test/").map { |c| c["name"] }).to eq([ "session" ])
      end
    end

    describe "#set" do
      it "defaults to the page's current URL, which the browser demands" do
        cookies.set("token", "abc")

        expect(page.last_params).to include(name: "token", value: "abc", url: "https://example.com/app")
      end

      it "translates the Ruby options into CDP spelling" do
        cookies.set("token", "abc", path: "/app", secure: true, http_only: true, same_site: "Strict")

        expect(page.last_params).to include(path: "/app", secure: true, httpOnly: true, sameSite: "Strict")
      end

      it "takes a Time for expires and sends epoch seconds" do
        at = Time.now + 600
        cookies.set("token", "abc", expires: at)

        expect(page.last_params[:expires]).to eq(at.to_i)
      end

      it "sends domain instead of url when given one" do
        cookies.set("token", "abc", domain: "example.com", path: "/")

        expect(page.last_params).to include(domain: "example.com")
        expect(page.last_params).not_to have_key(:url)
      end

      it "stringifies the name and value, as CDP requires" do
        cookies.set(:token, 42)

        expect(page.last_params).to include(name: "token", value: "42")
      end

      # Obscura accepts a bogus sameSite silently and stores Lax, so the only
      # place this can be caught is here.
      it "rejects a sameSite the browser would silently downgrade" do
        expect { cookies.set("token", "abc", same_site: "Nope") }
          .to raise_error(ArgumentError, /same_site/)
      end

      it "rejects an unknown option rather than letting the browser ignore it" do
        expect { cookies.set("token", "abc", httponly: true) }.to raise_error(ArgumentError, /httponly/)
      end

      # The replay flow reads a cookie and writes it straight back, so a read
      # that returned nil must fail loudly here rather than write an empty name.
      it "refuses a nil cookie, which is what a missed read looks like" do
        expect { cookies.set(nil) }.to raise_error(ArgumentError, /name/)
      end

      it "refuses an empty name" do
        expect { cookies.set("", "abc") }.to raise_error(ArgumentError, /name/)
      end

      it "refuses a cookie hash carrying no name" do
        expect { cookies.set({ "value" => "abc" }) }.to raise_error(ArgumentError, /name/)
      end

      it "takes a Date or DateTime for expires, not only a Time" do
        require "date"
        at = DateTime.now + 1

        cookies.set("token", "abc", expires: at)

        expect(page.last_params[:expires]).to eq(at.to_time.to_i)
      end

      it "refuses when there is no URL to attach the cookie to" do
        page.current_url = "about:blank"

        expect { cookies.set("token", "abc") }.to raise_error(ArgumentError, /url:|domain:/)
      end

      it "sends nothing to the browser when it refuses" do
        page.current_url = "about:blank"
        begin
          cookies.set("token", "abc")
        rescue ArgumentError
          nil
        end

        expect(page.methods_sent).to be_empty
      end

      it "takes a whole cookie hash, so one read here can be replayed elsewhere" do
        cookies.set(cookie("path" => "/app", "secure" => true))

        expect(page.last_params)
          .to include(name: "session", value: "abc123", domain: "example.com", path: "/app", secure: true)
      end

      it "drops the keys a read carries that a write cannot take" do
        cookies.set(cookie.merge("size" => 8, "session" => true, "sourcePort" => 443))

        expect(page.last_params.keys).not_to include(:size, :session, :sourcePort)
      end

      it "treats the -1 expiry of a session cookie as no expiry at all" do
        cookies.set(cookie("expires" => -1))

        expect(page.last_params).not_to have_key(:expires)
      end
    end

    describe "#remove" do
      def delete_params(page)
        page.sent.select { |method, _| method == "Network.deleteCookies" }.map(&:last)
      end

      # Measured: Network.deleteCookies compares the path exactly, so aiming a
      # delete at /app would leave a cookie set on / untouched. The domain and
      # path come from the jar entry instead.
      it "deletes at the exact domain and path the jar reports" do
        page.jar = [ cookie("path" => "/") ]

        cookies.remove("session")

        expect(delete_params(page)).to eq([ { name: "session", domain: "example.com", path: "/" } ])
      end

      it "sends nothing when the current URL would not send that cookie" do
        page.jar = [ cookie("domain" => "elsewhere.test") ]

        cookies.remove("session")

        expect(delete_params(page)).to be_empty
      end

      it "skips the lookup when told a path outright" do
        cookies.remove("session", path: "/deep")

        expect(delete_params(page)).to eq([ { name: "session", url: "https://example.com/app", path: "/deep" } ])
      end

      it "reports whether the jar actually changed" do
        page.jar = [ cookie ]

        expect(cookies.remove("session")).to be(false)
      end

      # The answer has to be about this cookie, not about the jar: another page
      # on the same connection writing between the two reads must not be
      # mistaken for a successful delete.
      it "ignores unrelated cookies appearing while it works" do
        page.jar = [ cookie("name" => "other") ]
        page.drift = true

        expect(cookies.remove("session")).to be(false)
      end

      it "refuses when there is no URL to match against, as #set does" do
        page.current_url = "about:blank"

        expect { cookies.remove("session", path: "/app") }.to raise_error(ArgumentError, /url:|domain:/)
      end

      it "still works from a blank page when told the domain" do
        cookies.remove("session", domain: "example.com", path: "/")

        expect(delete_params(page)).to eq([ { name: "session", domain: "example.com", path: "/" } ])
      end
    end

    describe "#inspect" do
      it "shows the cookies the current URL would send" do
        page.jar = [ cookie ]

        expect(cookies.inspect).to include("session=abc123")
      end

      # Consoles and debuggers call #inspect implicitly, so it must not raise
      # once the page or the connection is gone.
      it "degrades instead of raising when the browser is unreachable" do
        page.dead = true

        expect { cookies.inspect }.not_to raise_error
        expect(cookies.inspect).to include("Obxcura::Cookies")
      end
    end

    describe "#clear" do
      it "drops every cookie on the connection" do
        cookies.clear

        expect(page.methods_sent).to eq([ "Network.clearBrowserCookies" ])
      end
    end
  end

  describe "against the browser", :obscura do
    let(:browser) { Obxcura::Browser.new(port: ObscuraServer.port) }
    let(:page) { browser.create_page }

    after { browser.quit }

    # Navigates to the echo endpoint and returns the Cookie header the server
    # saw — the only witness of what the browser actually sent.
    def sent_to_server(page)
      page.goto(TestSite.url("/echo-cookies"))
      JSON.parse(page.evaluate("document.body.innerText"))["cookie"].to_s
    end

    it "reads the cookies the visited page set" do
      page.goto(TestSite.url("/cookies"))

      expect(page.cookies.map { |c| c["name"] }).to include("session")
    end

    # The reason to read cookies over CDP at all: document.cookie cannot see
    # HttpOnly ones, and a session cookie is usually HttpOnly.
    it "sees an HttpOnly cookie that the page itself cannot" do
      page.goto(TestSite.url("/cookies"))

      expect(page.evaluate("document.cookie")).not_to include("secret")
      expect(page.cookies.map { |c| c["name"] }).to include("secret")
    end

    it "withholds another host's cookies, which the raw jar still holds" do
      page.goto(TestSite.url("/cookies"))
      page.command("Network.setCookie", name: "elsewhere", value: "1", domain: "other.test", path: "/")

      expect(page.cookies.map { |c| c["name"] }).not_to include("elsewhere")
      expect(page.cookies.all.map { |c| c["name"] }).to include("elsewhere")
    end

    it "withholds a cookie scoped to a path the page is not under" do
      page.goto(TestSite.url("/deep/cookies"))
      expect(page.cookies.map { |c| c["name"] }).to include("deep")

      page.goto(TestSite.url("/"))

      expect(page.cookies.map { |c| c["name"] }).not_to include("deep")
    end

    it "scopes to an explicit URL when given one" do
      page.goto(TestSite.url("/deep/cookies"))
      page.goto(TestSite.url("/"))

      expect(page.cookies.for_url(TestSite.url("/deep")).map { |c| c["name"] }).to include("deep")
    end

    it "returns nothing on a page that has not navigated anywhere" do
      page.goto(TestSite.url("/cookies"))

      expect(browser.create_page.cookies.to_a).to eq([])
    end

    # Obscura answers every read with the whole connection jar — Network.getCookies
    # accepts `urls:` and ignores it — which is why the scoping happens in Ruby.
    it "keeps the raw jar connection-wide, not per page" do
      page.goto(TestSite.url("/cookies"))

      expect(browser.create_page.cookies.all.map { |c| c["name"] }).to include("session")
    end

    # Measured: Obscura keeps an expired cookie in the jar but stops sending it,
    # so the scoped view has to drop it or it misreports the request.
    it "hides an expired cookie that the jar still holds" do
      page.goto(TestSite.url("/"))
      page.cookies.set("stale", "1", expires: Time.now - 600)

      expect(page.cookies.all.map { |c| c["name"] }).to include("stale")
      expect(page.cookies.map { |c| c["name"] }).not_to include("stale")
      expect(sent_to_server(page)).not_to include("stale")
    end

    describe "writing" do
      it "sets a cookie the server then receives" do
        page.goto(TestSite.url("/"))
        page.cookies.set("token", "abc123")

        expect(sent_to_server(page)).to include("token=abc123")
      end

      it "sets an HttpOnly cookie the page itself cannot read" do
        page.goto(TestSite.url("/"))
        page.cookies.set("token", "abc123", http_only: true)

        expect(page.cookies["token"]["httpOnly"]).to be(true)
        expect(page.evaluate("document.cookie")).not_to include("token")
        expect(sent_to_server(page)).to include("token=abc123")
      end

      it "replays a cookie read from another browser" do
        page.goto(TestSite.url("/cookies"))
        saved = page.cookies["session"]

        other = Obxcura::Browser.new(port: ObscuraServer.port)
        begin
          fresh = other.go_to(TestSite.url("/"))
          expect(fresh.cookies.map { |c| c["name"] }).not_to include("session")

          fresh.cookies.set(saved)

          expect(fresh.cookies["session"]["value"]).to eq(saved["value"])
        ensure
          other.quit
        end
      end

      it "removes a cookie, and says that it did" do
        page.goto(TestSite.url("/cookies"))

        expect(page.cookies.remove("session")).to be(true)
        expect(page.cookies.map { |c| c["name"] }).not_to include("session")
      end

      # The trap: Network.deleteCookies matches on path too, so a delete aimed
      # at the root leaves a /deep cookie exactly where it was.
      it "does not remove a cookie scoped to another path, and says so" do
        page.goto(TestSite.url("/deep/cookies"))
        page.goto(TestSite.url("/"))

        expect(page.cookies.remove("deep")).to be(false)
        expect(page.cookies.for_url(TestSite.url("/deep")).map { |c| c["name"] }).to include("deep")
      end

      it "removes a path-scoped cookie when told which path" do
        page.goto(TestSite.url("/deep/cookies"))
        page.goto(TestSite.url("/"))

        expect(page.cookies.remove("deep", path: "/deep")).to be(true)
        expect(page.cookies.for_url(TestSite.url("/deep")).map { |c| c["name"] }).to be_empty
      end

      it "empties the whole jar with #clear" do
        page.goto(TestSite.url("/cookies"))
        page.cookies.set("elsewhere", "1", domain: "other.test", path: "/")

        page.cookies.clear

        expect(page.cookies.all).to be_empty
      end
    end
  end
end
