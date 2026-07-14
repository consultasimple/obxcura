# frozen_string_literal: true

RSpec.describe Obxcura::Client, :obscura do
  let(:browser) { Obxcura::Browser.new(port: ObscuraServer.port) }

  after { browser.quit }

  it "routes concurrent commands across pages over one connection" do
    a = browser.go_to(TestSite.url)
    b = browser.go_to(TestSite.url("/big"))
    expect(a.title).to eq("Obxcura Test")
    expect(b.html.bytesize).to be > 1_000_000
    # connection stays healthy after a large read
    expect(a.evaluate("document.title")).to eq("Obxcura Test")
  end

  it "times out slow commands" do
    page = browser.create_page
    # A promise that never settles: exercises the timeout path without leaving a
    # runaway loop burning CPU in the browser we share with every other spec.
    expect {
      browser.client.command(
        "Runtime.evaluate",
        { expression: "new Promise(() => {})", awaitPromise: true },
        session_id: page.session_id, timeout: 1
      )
    }.to raise_error(Obxcura::TimeoutError)
  end
end
