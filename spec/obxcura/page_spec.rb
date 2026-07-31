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

  it "queries nested elements" do
    page.goto(TestSite.url)

    node = page.at_css("form")

    expect(node.at_css("input")).to be_a(Obxcura::Node)
  end

  it "typing into a form control" do
    page.goto(TestSite.url)
    node = page.at_css("input")
    node.type("Hello, world!")
    expect(node.value).to eq("Hello, world!")
  end

  it "types through real key events, so keydown/input listeners fire" do
    page.goto(TestSite.url)
    page.evaluate(<<~JS)
      (() => {
        window.__types = [];
        window.__keys = [];
        const el = document.querySelector("#username");
        [ "keydown", "keyup", "input" ].forEach((t) =>
          el.addEventListener(t, () => window.__types.push(t)));
        el.addEventListener("keydown", (e) => window.__keys.push(e.key));
      })()
    JS

    page.at_css("#username").type("ab")

    expect(page.evaluate("window.__types.join(',')")).to eq("keydown,input,keyup,keydown,input,keyup")
    expect(page.evaluate("window.__keys.join('')")).to eq("ab")
  end

  it "appends when typing into a control that already has a value" do
    page.goto(TestSite.url)
    node = page.at_css("#username")
    node.type("AB")
    node.type("c")
    expect(node.value).to eq("ABc")
  end

  it "submitting a form" do
    page.goto(TestSite.url)
    node = page.at_css("form")
    node.at_css("input").type("Hello, world!")
    node.submit

    expect(page.at_css("#done").text).to eq("ok")
  end

  it "focuses a node" do
    page.goto(TestSite.url)
    page.at_css("#username").focus
    expect(page.evaluate("document.activeElement.id")).to eq("username")
  end

  it "returns a node's outer HTML" do
    page.goto(TestSite.url)
    expect(page.at_css("#greeting").outer_html).to eq('<h1 id="greeting">Hello Obxcura</h1>')
  end

  it "raises when submitting a node with no form" do
    page.goto(TestSite.url)
    expect { page.at_css("#greeting").submit }.to raise_error(Obxcura::ProtocolError, /no ancestor form/)
  end

  it "returns nil for a missing selector" do
    page.goto(TestSite.url)
    expect(page.at_css("#nope")).to be_nil
  end

  it "returns a multi-megabyte page in a single CDP message" do
    page.goto(TestSite.url("/big"))
    expect(page.html.bytesize).to be > 1_000_000
    expect(page.html).to include("</html>")
  end

  it "round-trips a string far past the old ~700KB ceiling" do
    page.goto(TestSite.url)
    length = page.evaluate("(window.__big = 'y'.repeat(8 * 1024 * 1024)).length")

    expect(page.evaluate("window.__big").length).to eq(length)
  end

  describe "#network_log" do
    it "records requests the navigation itself issued" do
      page.goto(TestSite.url)

      expect(page.network_log).to include(a_hash_including(url: TestSite.url, finished: true))
    end

    it "starts empty and stays scoped to the page that navigated" do
      other = browser.create_page
      page.goto(TestSite.url)

      expect(other.network_log).to be_empty
    end
  end

  describe "#post" do
    before { page.goto(TestSite.url) }

    it "is still reachable under the deprecated xhr_post name" do
      expect(page.xhr_post(TestSite.url("/echo"), "q=hi", "text/plain", {})["status"]).to eq(200)
    end

    it "sends the payload, content type and headers, and returns the response" do
      result = page.post(TestSite.url("/echo"), "q=hi", "application/x-www-form-urlencoded", { "X-Test" => "42" })

      expect(result["status"]).to eq(200)
      expect(result["ok"]).to be(true)

      echoed = JSON.parse(result["body"])
      expect(echoed["method"]).to eq("POST")
      expect(echoed["body"]).to eq("q=hi")
      expect(echoed["content_type"]).to eq("application/x-www-form-urlencoded")
      expect(echoed["x_test"]).to eq("42")
    end

    it "returns ok:false on an HTTP error status without raising" do
      result = page.post(TestSite.url("/boom"), "q=hi", "application/x-www-form-urlencoded", {})

      expect(result["status"]).to eq(500)
      expect(result["ok"]).to be(false)
    end

    it "raises ConnectionError when the request can't reach the server" do
      expect { page.post("http://127.0.0.1:1/nope", "", "application/json", {}) }
        .to raise_error(Obxcura::ConnectionError)
    end

    it "times out in the page when the server accepts but never answers" do
      tarpit = TCPServer.new("127.0.0.1", 0)
      held = []
      accepter = Thread.new { loop { held << tarpit.accept } }
      url = "http://127.0.0.1:#{tarpit.addr[1]}/"

      started = Time.now
      expect { page.post(url, "q=1", "application/x-www-form-urlencoded", {}, timeout: 2) }
        .to raise_error(Obxcura::TimeoutError, /did not complete in time/)

      # The in-page timer wins the race, so we give up at roughly `timeout:`
      # rather than sitting out the CDP reply timeout — all the old XHR path
      # could do, since Obscura ignores XMLHttpRequest#timeout.
      expect(Time.now - started).to be < Obxcura::Client::DEFAULT_TIMEOUT
    ensure
      accepter&.kill
      held&.each(&:close)
      tarpit&.close
    end
  end
end
