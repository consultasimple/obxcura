# frozen_string_literal: true

# Screenshotting a page behind an anti-bot layer (Imperva/Incapsula).
#
# Needs a browser started in stealth mode:
#
#   obscura --stealth serve --port 9222
#   ruby examples/stealth.rb
#
# Override the port with OBSCURA_PORT, the target with URL, and the output path
# with OUT.
#
# Stealth takes TWO halves and neither is optional:
#
#   1. the `-stealth` release build, which carries TLS impersonation, and
#   2. the `--stealth` flag on the process.
#
# Drop either one and the TLS handshake falls back to Obscura's native stack —
# JA4 `t13d1011h1…`, ALPN h1 — while the User-Agent still claims Chrome. That
# mismatch is what the anti-bot layer reads. With both halves the handshake is a
# real Chrome one (`t13d1516h2…`, ALPN h2). Neither half announces itself: the
# flag is accepted on a non-stealth build without warning, and all four release
# builds answer `--version` identically, so measure rather than assume.
#
# The fingerprint buys you the right to be challenged, not the right to get in.
# A session that has already cleared the challenge holds the clearance cookies;
# a cold one has to earn them, and an IP that has been hammered may simply not
# be allowed to. Expect this script to fail sometimes and to succeed on a later
# run from the same machine — that is the anti-bot layer working, not a bug
# here. Space your runs out.

require "./lib/obxcura"
require "fileutils"

PORT = Integer(ENV.fetch("OBSCURA_PORT", 9222))
URL = ENV.fetch(
  "URL",
  "https://serviciosdigitales.imss.gob.mx/semanascotizadas-web/usuarios/IngresoAsegurado"
)
OUT = ENV.fetch("OUT", File.expand_path("../tmp/screenshots/stealth.png", __dir__))

# The interstitial answers 200 with a plausible-looking document, so "did the
# navigation succeed?" is the wrong question — every request succeeds. Read the
# body instead.
BLOCK_MARKER = "Incapsula incident ID"

FileUtils.mkdir_p(File.dirname(OUT))

browser =
  begin
    Obxcura::Browser.new(port: PORT)
  rescue Obxcura::ConnectionError => e
    abort "#{e.message}\nStart one with: obscura --stealth serve --port #{PORT}"
  end

begin
  page = browser.go_to(URL)

  title = page.title
  blocked = page.evaluate("document.body.innerText").include?(BLOCK_MARKER)

  puts "url:     #{page.current_url}"
  puts "title:   #{title.inspect}"
  puts "blocked: #{blocked}"

  if blocked
    abort <<~MSG
      Served the anti-bot interstitial instead of the page.

      Check, in this order:
        1. Is the browser running with --stealth? (`ps | grep obscura`)
        2. Is it the -stealth build? All builds report the same --version, so
           compare the binary's SHA-256 against the release asset you installed.
        3. Neither of the above? Then it is the session or the IP. Wait a few
           minutes and run it again.
    MSG
  end

  path = page.screenshot(path: OUT, full_page: true)
  puts "written: #{path} (#{File.size(path)} bytes)"
rescue Obxcura::Error => e
  abort "#{e.class}: #{e.message}"
ensure
  browser.quit
end
