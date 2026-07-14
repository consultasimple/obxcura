# frozen_string_literal: true

RSpec.describe Obxcura::Frame, :obscura do
  let(:browser) { Obxcura::Browser.new(port: ObscuraServer.port) }
  let(:page) { browser.create_page }

  after { browser.quit }

  it "passes Ruby values into JS as arguments, not interpolated source" do
    expect(page.evaluate("arguments[0] + arguments[1]", 2, 3)).to eq(5)
  end

  it "does not treat argument strings as code (no injection)" do
    expect(page.evaluate("arguments[0]", "1); throw new Error('x')")).to eq("1); throw new Error('x')")
  end

  it "invokes a function declaration directly via #evaluate_func" do
    expect(page.evaluate_func("function(a, b) { return a * b; }", 6, 7)).to eq(42)
  end

  it "still evaluates argument-free expressions in a single round trip" do
    page.goto(TestSite.url)
    expect(page.evaluate("document.title")).to eq("Obxcura Test")
  end
end
