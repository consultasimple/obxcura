# frozen_string_literal: true

# Page#pdf against a live site.
#
# Needs a running browser built WITH the render feature (the -no-render release
# archives refuse to print):
#
#   obscura serve --port 9222
#   ruby examples/pdf.rb
#
# Override the port with OBSCURA_PORT, and the output directory with OUT_DIR.

require "obxcura"
require "fileutils"

PORT = Integer(ENV.fetch("OBSCURA_PORT", 9222))
OUT_DIR = ENV.fetch("OUT_DIR", File.expand_path("../tmp/pdf", __dir__))

FileUtils.mkdir_p(OUT_DIR)

def report(path)
  raw = File.binread(path)
  pages = raw.scan(%r{/Type\s*/Page[^s]}).length
  puts format("  %-20s %8d bytes  %d page(s)", File.basename(path), raw.bytesize, pages)
end

browser =
  begin
    Obxcura::Browser.new(port: PORT)
  rescue Obxcura::ConnectionError => e
    abort "#{e.message}\nStart one with: obscura serve --port #{PORT}"
  end

begin
  page = browser.go_to("https://example.com")
  puts "title: #{page.title}"
  puts "writing to #{OUT_DIR}"

  # 1. Simplest form: US Letter, default margins. Returns the path.
  report page.pdf(path: File.join(OUT_DIR, "default.pdf"))

  # 2. Named paper sizes: :letter, :legal, :tabloid, :a3, :a4, :a5.
  #    Pass paper_width:/paper_height: in inches instead for anything else.
  report page.pdf(path: File.join(OUT_DIR, "a4.pdf"), paper: :a4)

  # 3. Landscape swaps the page box, and print_background paints backgrounds
  #    and images that print stylesheets would otherwise drop.
  report page.pdf(path: File.join(OUT_DIR, "landscape.pdf"),
    landscape: true, print_background: true)

  # 4. Margins in inches: one number for all four sides, or per side.
  report page.pdf(path: File.join(OUT_DIR, "edge-to-edge.pdf"), margin: 0)
  report page.pdf(path: File.join(OUT_DIR, "wide-margins.pdf"),
    margin: { top: 1.5, bottom: 1.5, left: 1, right: 1 })

  # 5. scale is 0.1..2.0 — smaller fits more of the document per page. Combine
  #    with page_ranges to print only part of a long document.
  report page.pdf(path: File.join(OUT_DIR, "small-first-page.pdf"),
    scale: 0.5, page_ranges: "1")

  # 6. Without path: the raw bytes, so nothing has to touch disk.
  bytes = page.pdf
  puts format("  %-20s %8d bytes  (in memory, PDF: %s)",
    "<no path>", bytes.bytesize, bytes.start_with?("%PDF-"))

  # 7. Obscura's PDF output is raster-backed: each page is a drawn image, so
  #    there is no selectable or searchable text in it. Verify rather than
  #    trust — if you need extractable text, use page.html, not this.
  raw = File.binread(File.join(OUT_DIR, "default.pdf"))
  puts "  fonts: #{raw.scan(%r{/Font}).length}, " \
       "images: #{raw.scan(%r{/Subtype\s*/Image}).length} " \
       "-> text is drawn, not selectable"
rescue Obxcura::Error => e
  abort "#{e.class}: #{e.message}"
ensure
  browser.quit
end
