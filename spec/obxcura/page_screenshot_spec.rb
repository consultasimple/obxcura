# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Obxcura::Page#screenshot" do
  # Byte signatures, so assertions are about the actual image and not about
  # whatever the browser claimed in the CDP reply.
  def png?(data) = data.start_with?("\x89PNG\r\n\x1A\n".b)
  def jpeg?(data) = data[0, 3] == "\xFF\xD8\xFF".b
  def webp?(data) = data[0, 4] == "RIFF".b && data[8, 4] == "WEBP".b

  # PNG header: width and height are two big-endian uint32 at offset 16.
  def png_dimensions(data) = data[16, 8].unpack("N2")

  describe "argument validation" do
    let(:page) { Obxcura::Page.allocate }

    it "rejects an unsupported format without a round trip to the browser" do
      expect(page).not_to receive(:command)
      expect { page.screenshot(format: :gif) }
        .to raise_error(ArgumentError, /gif.*png.*jpeg.*webp/i)
    end

    it "rejects quality on png, where it would be silently ignored" do
      expect(page).not_to receive(:command)
      expect { page.screenshot(format: :png, quality: 50) }
        .to raise_error(ArgumentError, /quality/i)
    end

    # Obscura's webp encoder is lossless in 0.2.0 and answers any quality at
    # all — including 0 and 100 — with "WebP screenshot quality is not
    # supported by the current lossless encoder". Catch it before the trip.
    it "rejects quality on webp, whose encoder is lossless" do
      expect(page).not_to receive(:command)
      expect { page.screenshot(format: :webp, quality: 60) }
        .to raise_error(ArgumentError, /quality.*jpeg|jpeg.*quality/i)
    end

    it "rejects a quality outside 0..100" do
      expect { page.screenshot(format: :jpeg, quality: 150) }
        .to raise_error(ArgumentError, /0.*100/)
    end

    it "rejects full_page together with clip, which contradict each other" do
      expect(page).not_to receive(:command)
      expect { page.screenshot(full_page: true, clip: { x: 0, y: 0, width: 10, height: 10 }) }
        .to raise_error(ArgumentError, /full_page.*clip|clip.*full_page/i)
    end

    it "rejects a clip missing its dimensions" do
      expect { page.screenshot(clip: { x: 0, y: 0 }) }
        .to raise_error(ArgumentError, /width.*height|height.*width/i)
    end
  end

  describe "when the browser has no render feature" do
    let(:page) { Obxcura::Page.allocate }

    it "raises a friendly error naming the build, not a raw ProtocolError" do
      allow(page).to receive(:command)
        .and_raise(Obxcura::ProtocolError, "Page.captureScreenshot requires a build with the render feature")

      expect { page.screenshot }
        .to raise_error(Obxcura::Error, /render/i) { |e| expect(e.message).to match(/asset|build/i) }
    end
  end

  describe "capturing", :obscura, :render do
    # One browser and one page for the whole group, not one per example.
    #
    # Capturing is read-only, so there is nothing to isolate between examples —
    # and rasterising is expensive enough that a browser-per-example saturated
    # the CI runner until `Target.createTarget` hit its 30s ceiling. Same reason
    # the suite shares a single `obscura serve`.
    #
    # Guarded rather than lazy: a context hook runs even when the per-example
    # :obscura/:render tags would skip, and there is no port to dial then.
    before(:context) do
      if ObscuraServer.available? && ObscuraServer.render?
        @browser = Obxcura::Browser.new(port: ObscuraServer.port)
        @shared_page = @browser.go_to(TestSite.url("/tall"))
      end
    end

    after(:context) { @browser&.quit }

    let(:page) { @shared_page }

    it "returns raw PNG bytes by default" do
      data = page.screenshot

      expect(png?(data)).to be true
      expect(data.encoding).to eq(Encoding::BINARY)
    end

    it "captures the viewport, not the whole document, by default" do
      _width, height = png_dimensions(page.screenshot)

      expect(height).to eq(720)
    end

    it "captures past the viewport with full_page" do
      _width, height = png_dimensions(page.screenshot(full_page: true))

      expect(height).to be > 2_000
    end

    it "captures only the requested region with clip" do
      data = page.screenshot(clip: { x: 0, y: 0, width: 300, height: 200 })

      expect(png_dimensions(data)).to eq([ 300, 200 ])
    end

    it "scales a clipped region" do
      data = page.screenshot(clip: { x: 0, y: 0, width: 300, height: 200, scale: 2 })

      expect(png_dimensions(data)).to eq([ 600, 400 ])
    end

    it "captures jpeg" do
      expect(jpeg?(page.screenshot(format: :jpeg))).to be true
    end

    it "captures webp" do
      expect(webp?(page.screenshot(format: :webp))).to be true
    end

    it "honours jpeg quality" do
      low = page.screenshot(format: :jpeg, quality: 1)
      high = page.screenshot(format: :jpeg, quality: 100)

      expect(high.bytesize).to be > low.bytesize
    end

    it "writes to path and returns the path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "shot.png")

        expect(page.screenshot(path: path)).to eq(path)
        expect(png?(File.binread(path))).to be true
      end
    end

    it "infers the format from the path extension" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "shot.jpg")
        page.screenshot(path: path)

        expect(jpeg?(File.binread(path))).to be true
      end
    end

    it "lets an explicit format win over the extension" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "shot.jpg")
        page.screenshot(path: path, format: :png)

        expect(png?(File.binread(path))).to be true
      end
    end
  end
end
