# frozen_string_literal: true

RSpec.describe Obxcura::Browser, :obscura do
  subject(:browser) { described_class.new(port: ObscuraServer.port) }

  after { browser.quit }

  it "reports the underlying browser version" do
    expect(browser.version["Browser"]).to include("Chrome")
  end

  it "creates and tracks pages" do
    page = browser.create_page
    expect(page).to be_a(Obxcura::Page)
    expect(browser.pages).to include(page)
    page.close
    expect(browser.pages).not_to include(page)
  end

  it "navigates via #go_to" do
    page = browser.go_to(TestSite.url)
    expect(page.title).to eq("Obxcura Test")
  end

  it "raises ConnectionError when nothing is listening" do
    expect { described_class.new(port: 1) }.to raise_error(Obxcura::ConnectionError)
  end
end
