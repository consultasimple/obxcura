# frozen_string_literal: true

RSpec.describe Obxcura::Page, :obscura do
  let(:browser) { Obxcura::Browser.new(port: ObscuraServer.port) }
  let(:page) { browser.create_page }

  after { browser.quit }

  it "returns rendered HTML and title" do
    page.goto(TestSite.url)
    expect(page.html).to include("Hello Obxcura")
    expect(page.title).to eq("Obxcura Test")
    expect(page.current_url).to eq(TestSite.url)
  end

  it "evaluates JavaScript" do
    page.goto(TestSite.url)
    expect(page.evaluate("1 + 2")).to eq(3)
  end

  it "queries the DOM as a live node" do
    page.goto(TestSite.url)
    node = page.at_css("#greeting")
    expect(node.text).to eq("Hello Obxcura")
    expect(node["id"]).to eq("greeting")
  end

  it "returns nil for a missing selector" do
    page.goto(TestSite.url)
    expect(page.at_css("#nope")).to be_nil
  end

  it "chunks large pages past Obscura's single-message ceiling" do
    page.goto(TestSite.url("/big"))
    expect(page.html.bytesize).to be > 1_000_000
    expect(page.html).to include("</html>")
  end

  describe "#xhr_post" do
    before { page.goto(TestSite.url) }

    it "sends the payload, content type and headers, and returns the response" do
      result = page.xhr_post(TestSite.url("/echo"), "q=hi", "application/x-www-form-urlencoded", { "X-Test" => "42" })

      expect(result["status"]).to eq(200)
      expect(result["ok"]).to be(true)

      echoed = JSON.parse(result["body"])
      expect(echoed["method"]).to eq("POST")
      expect(echoed["body"]).to eq("q=hi")
      expect(echoed["content_type"]).to eq("application/x-www-form-urlencoded")
      expect(echoed["x_test"]).to eq("42")
    end

    it "returns ok:false on an HTTP error status without raising" do
      result = page.xhr_post(TestSite.url("/boom"), "q=hi", "application/x-www-form-urlencoded", {})

      expect(result["status"]).to eq(500)
      expect(result["ok"]).to be(false)
    end

    it "raises ConnectionError when the request can't reach the server" do
      expect { page.xhr_post("http://127.0.0.1:1/nope", "", "application/json", {}) }
        .to raise_error(Obxcura::ConnectionError)
    end

    it "raises TimeoutError when the server accepts but never answers" do
      tarpit = TCPServer.new("127.0.0.1", 0)
      held = []
      accepter = Thread.new { loop { held << tarpit.accept } }
      url = "http://127.0.0.1:#{tarpit.addr[1]}/"

      expect { page.xhr_post(url, "q=1", "application/x-www-form-urlencoded", {}, timeout: 2) }
        .to raise_error(Obxcura::TimeoutError, /did not complete in time/)
    ensure
      accepter&.kill
      held&.each(&:close)
      tarpit&.close
    end
  end
end
