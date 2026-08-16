# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Obxcura::Page#pdf" do
  def pdf?(data) = data.start_with?("%PDF-")

  # PDF page boxes are in points (1/72 inch), so a MediaBox is the authoritative
  # answer to "did paper size actually apply?" — byte length is not: an A4 render
  # of this page happens to weigh exactly as much as the Letter one.
  def media_boxes(data)
    data.scan(%r{/MediaBox\s*\[([^\]]+)\]}).flatten.uniq
        .map { |b| b.split.map(&:to_f)[2, 2].map(&:round) }
  end

  def page_count(data) = data.scan(%r{/Type\s*/Page[^s]}).length

  describe "argument validation" do
    let(:page) { Obxcura::Page.allocate }

    it "rejects an unknown paper name" do
      expect(page).not_to receive(:command)
      expect { page.pdf(paper: :foolscap) }
        .to raise_error(ArgumentError, /foolscap.*a4|a4.*foolscap/im)
    end

    it "rejects paper together with explicit dimensions" do
      expect(page).not_to receive(:command)
      expect { page.pdf(paper: :a4, paper_width: 8.5) }
        .to raise_error(ArgumentError, /paper.*width|width.*paper/im)
    end

    # Obscura's own bound, worth failing fast on so the message names the Ruby
    # option rather than the CDP one.
    it "rejects a scale outside 0.1..2" do
      expect(page).not_to receive(:command)
      expect { page.pdf(scale: 5) }.to raise_error(ArgumentError, /scale.*0\.1.*2/m)
    end
  end

  describe "when the browser has no render feature" do
    let(:page) { Obxcura::Page.allocate }

    it "raises a friendly error naming the build, not a raw ProtocolError" do
      allow(page).to receive(:command)
        .and_raise(Obxcura::ProtocolError, "Page.printToPDF requires a build with the render feature")

      expect { page.pdf }.to raise_error(Obxcura::Error, /render/i)
    end
  end

  describe "printing", :obscura, :render do
    # One browser and page for the group: printing is read-only and expensive,
    # and a browser per example is what saturated CI for the screenshot specs.
    before(:context) do
      if ObscuraServer.available? && ObscuraServer.render?
        @browser = Obxcura::Browser.new(port: ObscuraServer.port)
        @shared_page = @browser.go_to(TestSite.url("/tall"))
      end
    end

    after(:context) { @browser&.quit }

    let(:page) { @shared_page }

    it "returns raw PDF bytes by default" do
      data = page.pdf

      expect(pdf?(data)).to be true
      expect(data.encoding).to eq(Encoding::BINARY)
    end

    it "defaults to US Letter, 612x792 points" do
      expect(media_boxes(page.pdf)).to eq([ [ 612, 792 ] ])
    end

    it "applies a named paper size" do
      # A4 is 8.27x11.69in, so 595.44x841.68pt.
      expect(media_boxes(page.pdf(paper: :a4))).to eq([ [ 595, 842 ] ])
    end

    it "applies explicit paper dimensions in inches" do
      expect(media_boxes(page.pdf(paper_width: 3, paper_height: 3))).to eq([ [ 216, 216 ] ])
    end

    it "swaps the page box in landscape" do
      expect(media_boxes(page.pdf(landscape: true))).to eq([ [ 792, 612 ] ])
    end

    it "fits more of the document per page as scale shrinks" do
      expect(page_count(page.pdf(scale: 0.5))).to be < page_count(page.pdf(scale: 1.5))
    end

    it "limits output to the requested page range" do
      expect(page_count(page.pdf(page_ranges: "1"))).to eq(1)
    end

    it "includes backgrounds on request" do
      plain = page.pdf
      painted = page.pdf(print_background: true)

      expect(painted.bytesize).to be > plain.bytesize
    end

    it "accepts a uniform margin" do
      expect(pdf?(page.pdf(margin: 0))).to be true
    end

    it "accepts per-side margins" do
      data = page.pdf(margin: { top: 1, bottom: 1, left: 0.5, right: 0.5 })

      expect(pdf?(data)).to be true
    end

    it "writes to path and returns the path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "doc.pdf")

        expect(page.pdf(path: path)).to eq(path)
        expect(pdf?(File.binread(path))).to be true
      end
    end

    it "surfaces an unsupported option as a ProtocolError from the browser" do
      # Obscura has no header/footer support yet; it says so plainly, and the
      # gem does not pretend otherwise by silently dropping the request.
      expect { page.command("Page.printToPDF", displayHeaderFooter: true) }
        .to raise_error(Obxcura::ProtocolError, /headers and footers/i)
    end
  end
end
