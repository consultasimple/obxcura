# frozen_string_literal: true

RSpec.describe Obxcura::Client, :obscura do
  it "routes concurrent commands across pages over one connection" do
    browser = Obxcura::Browser.new(port: ObscuraServer.port)
    a = browser.go_to(TestSite.url)
    b = browser.go_to(TestSite.url("/big"))
    expect(a.title).to eq("Obxcura Test")
    expect(b.html.bytesize).to be > 1_000_000
    # connection stays healthy after a large read
    expect(a.evaluate("document.title")).to eq("Obxcura Test")
  ensure
    browser&.quit
  end

  it "times out slow commands" do
    browser = Obxcura::Browser.new(port: ObscuraServer.port)
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
  ensure
    # Drop the socket instead of calling Browser#quit.
    #
    # An unsettled `awaitPromise` starves its whole connection until the browser
    # gives up on it, and Obscura 0.2.0 raised that cap from ~4s to ~30s. Since
    # #quit first sends Target.closeTarget over this very connection, it would
    # sit behind the pinned promise and cost the suite ~30s — measured. Closing
    # the client just drops the socket, so nothing waits.
    #
    # Safe for the rest of the run: the starvation is scoped to one connection.
    # Every other spec dials its own, and those stay responsive (also measured).
    browser&.client&.close
  end
end
