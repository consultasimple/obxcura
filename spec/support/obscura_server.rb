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
