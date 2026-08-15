# frozen_string_literal: true

# Page#screenshot against a live site.
#
# Needs a running browser built WITH the render feature (the -no-render release
# archives refuse to rasterise):
#
#   obscura serve --port 9222
#   ruby examples/screenshot.rb
#
# Override the port with OBSCURA_PORT, and the output directory with OUT_DIR.

require "obxcura"
require "fileutils"

PORT = Integer(ENV.fetch("OBSCURA_PORT", 9222))
OUT_DIR = ENV.fetch("OUT_DIR", File.expand_path("../tmp/screenshots", __dir__))

FileUtils.mkdir_p(OUT_DIR)

def report(path)
  puts format("  %-22s %8d bytes", File.basename(path), File.size(path))
end

browser =
  begin
    Obxcura::Browser.new(port: PORT)
  rescue Obxcura::ConnectionError => e
    abort "#{e.message}\nStart one with: obscura serve --port #{PORT}"
  end

begin
  page = browser.go_to("https://www.google.com")

  puts "title: #{page.title}"
  puts "url:   #{page.current_url}"
  puts "writing to #{OUT_DIR}"

  # 1. Simplest form: PNG of the viewport, written to disk. Returns the path.
  report page.screenshot(path: File.join(OUT_DIR, "google.png"))

  # 2. The whole document rather than the viewport. On a page that already fits
  #    in the viewport — Google's home does — this is the same size; the
  #    difference shows up on anything that scrolls.
  report page.screenshot(path: File.join(OUT_DIR, "google-full.png"), full_page: true)

  # 3. Other formats. The extension picks the encoder, so no format: needed.
  #    quality: is 0..100 and applies to jpeg ONLY — png ignores it, and
  #    Obscura's webp encoder is lossless and refuses it outright.
  report page.screenshot(path: File.join(OUT_DIR, "google.jpg"), quality: 70)
  report page.screenshot(path: File.join(OUT_DIR, "google.webp"))

  # 4. A region. scale: multiplies the raster, so this writes 1280x400 pixels
  #    from a 640x200 slice of the page — handy for retina-density crops.
  report page.screenshot(
    path: File.join(OUT_DIR, "google-crop.png"),
    clip: { x: 0, y: 0, width: 640, height: 200, scale: 2 }
  )

  # 5. Without path: you get the raw bytes back, so nothing has to touch disk.
  #    Base64 is a CDP transport detail and is already decoded for you.
  bytes = page.screenshot
  puts format("  %-22s %8d bytes (in memory, PNG: %s)",
    "<no path>", bytes.bytesize, bytes.start_with?("\x89PNG".b))

  # 6. Screenshots are how you find out what the browser ACTUALLY got. Google
  #    answers headless traffic on /search with an anti-bot interstitial, so
  #    the result selectors below find nothing — and the image shows you why,
  #    instead of leaving you to blame the selector.
  results = browser.go_to("https://www.google.com/search?q=ruby+headless+browser")
  headings = results.css("h3").map(&:text)
  report results.screenshot(path: File.join(OUT_DIR, "google-search.png"))
  puts "  h3 headings found: #{headings.length}"
  puts "  ^ zero usually means an interstitial, not a broken selector — open the png"
rescue Obxcura::Error => e
  abort "#{e.class}: #{e.message}"
ensure
  browser.quit
end
