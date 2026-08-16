# frozen_string_literal: true

RSpec.describe Obxcura::Headers do
  # A stand-in for Page: records what would go on the wire, so the bookkeeping
  # can be tested without a browser.
  let(:page) do
    Class.new do
      attr_reader :sent

      def initialize = @sent = []
      def command(method, params = {}) = @sent << [ method, params ]
      def last_headers = @sent.last&.last&.fetch(:headers, nil)
    end.new
  end

  subject(:headers) { described_class.new(page) }

  describe "reading" do
    it "starts empty" do
      expect(headers.get).to eq({})
      expect(headers).to be_empty
    end

    it "reads one header back by name" do
      headers.set("X-Token" => "abc")

      expect(headers["X-Token"]).to eq("abc")
    end

    it "reads names case-insensitively, since HTTP header names are" do
      headers.set("X-Token" => "abc")

      expect(headers["x-token"]).to eq("abc")
      expect(headers).to be_key("X-TOKEN")
    end

    it "returns a copy, so callers cannot mutate the tracked state" do
      headers.set("X-Token" => "abc")
      headers.get["X-Token"] = "tampered"

      expect(headers["X-Token"]).to eq("abc")
    end
  end

  describe "#set" do
    it "replaces everything, matching what the browser does" do
      headers.set("X-One" => "1")
      headers.set("X-Two" => "2")

      expect(headers.get).to eq({ "X-Two" => "2" })
    end

    it "sends the whole table to the browser" do
      headers.set("X-One" => "1")

      expect(page.sent.last.first).to eq("Network.setExtraHTTPHeaders")
      expect(page.last_headers).to eq({ "X-One" => "1" })
    end

    it "stringifies names and values, which CDP requires" do
      headers.set(:"X-Num" => 42)

      expect(headers.get).to eq({ "X-Num" => "42" })
    end
  end

  describe "#add" do
    it "merges instead of replacing" do
      headers.set("X-One" => "1")
      headers.add("X-Two" => "2")

      expect(headers.get).to eq({ "X-One" => "1", "X-Two" => "2" })
    end

    it "overwrites a name that differs only in case, rather than duplicating it" do
      headers.add("x-token" => "old")
      headers.add("X-Token" => "new")

      expect(headers.get).to eq({ "X-Token" => "new" })
    end
  end

  describe "writing one at a time" do
    it "sets a single header with #[]=" do
      headers["X-Token"] = "abc"

      expect(headers.get).to eq({ "X-Token" => "abc" })
    end

    it "keeps the others, unlike #set" do
      headers["X-One"] = "1"
      headers["X-Two"] = "2"

      expect(headers.get).to eq({ "X-One" => "1", "X-Two" => "2" })
    end

    it "removes one with #delete, case-insensitively" do
      headers.set("X-One" => "1", "X-Two" => "2")

      expect(headers.delete("x-one")).to eq("1")
      expect(headers.get).to eq({ "X-Two" => "2" })
    end

    it "returns nil deleting something that was never there, and sends nothing" do
      before = page.sent.length

      expect(headers.delete("X-Ghost")).to be_nil
      expect(page.sent.length).to eq(before)
    end
  end

  describe "#clear" do
    it "empties the table" do
      headers.set("X-One" => "1")
      headers.clear

      expect(headers.get).to eq({})
      expect(headers).to be_empty
    end

    it "tells the browser with an empty hash, which is how CDP unsets them" do
      headers.set("X-One" => "1")
      headers.clear

      expect(page.last_headers).to eq({})
    end
  end

  describe "reaching the server", :obscura do
    let(:browser) { Obxcura::Browser.new(port: ObscuraServer.port) }
    let(:page) { browser.create_page }

    after { browser.quit }

    def received(page)
      page.goto(TestSite.url("/headers"))
      JSON.parse(page.evaluate("document.body.innerText"))
    end

    it "sends them on navigation" do
      page.headers.set("X-Token" => "abc123")

      expect(received(page)["x-token"]).to eq("abc123")
    end

    it "survives a reload" do
      page.headers.set("X-Token" => "abc123")
      received(page)
      page.reload

      expect(JSON.parse(page.evaluate("document.body.innerText"))["x-token"]).to eq("abc123")
    end

    it "stops sending them after #clear" do
      page.headers.set("X-Token" => "abc123")
      received(page)
      page.headers.clear

      expect(received(page)["x-token"]).to be_nil
    end

    it "can override the User-Agent" do
      page.headers.set("User-Agent" => "Obxcura/test")

      expect(received(page)["user-agent"]).to eq("Obxcura/test")
    end

    # Measured, and the reason Headers documents its scope the way it does:
    # Obscura applies the table per connection, not per session.
    it "applies to every page on the same connection, not just this one" do
      other = browser.create_page
      page.headers.set("X-Shared" => "yes")

      expect(received(other)["x-shared"]).to eq("yes")
    end

    # Also measured: extra headers cover navigation only. Script-initiated
    # requests never carry them, so #post needs its own headers argument.
    it "does not reach a fetch issued by #post" do
      page.goto(TestSite.url("/headers"))
      page.headers.set("X-Token" => "abc123")

      body = JSON.parse(page.post(TestSite.url("/headers"), "", "text/plain", {})["body"])

      expect(body["x-token"]).to be_nil
    end

    it "leaves #post's own per-call headers working" do
      page.goto(TestSite.url("/headers"))

      body = JSON.parse(page.post(TestSite.url("/headers"), "", "text/plain", { "X-Call" => "yes" })["body"])

      expect(body["x-call"]).to eq("yes")
    end
  end
end
