# frozen_string_literal: true

require "socket"
require "net/http"
require "uri"

# Boots a single `obscura serve` process (the external browser) for the suite
# and exposes its port. This is NOT the Obxcura client under test.
module ObscuraServer
  module_function

  def binary
    ENV["OBSCURA_BIN"] || "obscura"
  end

  # `system` returns nil (not raises) when the binary isn't executable/found.
  def available?
    system(binary, "--version", out: File::NULL, err: File::NULL)
  end

  def boot
    @port = free_port
    @pid = spawn(binary, "serve", "--port", @port.to_s, "--allow-private-network",
      out: File::NULL, err: File::NULL)
    wait_until_up(@port)
    @port
  end

  def shutdown
    return unless @pid

    Process.kill("TERM", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  ensure
    @pid = nil
  end

  def port
    @port
  end

  # Boot a throwaway `obscura serve` for one example and kill it afterwards.
  #
  # The suite shares a single browser process, so an example that can take that
  # process down would cascade into every example after it. Anything exercising
  # a known crash runs against its own.
  #
  # @yieldparam port [Integer] the throwaway server's port.
  def isolated
    port = free_port
    pid = spawn(binary, "serve", "--port", port.to_s, "--allow-private-network",
      out: File::NULL, err: File::NULL)
    wait_until_up(port)
    yield port
  ensure
    begin
      Process.kill("KILL", pid) if pid
      Process.wait(pid) if pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  # Whether the running binary was built with the render feature.
  #
  # 0.2.0 ships render and no-render builds of the same version, so `--version`
  # cannot tell them apart — the only honest answer is to ask the browser to
  # take a screenshot and see whether it refuses. Requires {boot} first.
  def render?
    return @render unless @render.nil?

    browser = Obxcura::Browser.new(port: port)
    begin
      browser.create_page.command("Page.captureScreenshot", format: "png")
      @render = true
    rescue Obxcura::ProtocolError
      @render = false
    ensure
      browser.quit
    end
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_until_up(port, timeout: 15)
    deadline = Time.now + timeout
    loop do
      Net::HTTP.get(URI("http://127.0.0.1:#{port}/json/version"))
      return
    rescue SystemCallError
      raise "obscura did not come up on port #{port}" if Time.now > deadline

      sleep 0.1
    end
  end
end
