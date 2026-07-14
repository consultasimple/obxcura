# frozen_string_literal: true

require "webrick"
require "json"

# Minimal local site so navigation specs are deterministic and offline.
module TestSite
  PAGES = {
    "/" => "<!doctype html><html><head><title>Obxcura Test</title></head>" \
           "<body><h1 id=\"greeting\">Hello Obxcura</h1>" \
           "<form action=\"/submit\" method=\"post\">" \
           "<input type=\"text\" name=\"username\" id=\"username\"><button type=\"submit\">Go</button></form>" \
           "</body></html>",
    "/big" => "<!doctype html><html><body><div>#{"x" * 1_200_000}</div></body></html>",
    "/submit" => "<!doctype html><html><body id=\"done\">ok</body></html>"
  }.freeze

  module_function

  def boot
    @port = free_port
    @server = WEBrick::HTTPServer.new(
      Port: @port, BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    PAGES.each do |path, body|
      @server.mount_proc(path) do |_req, res|
        res.content_type = "text/html"
        res.body = body
      end
    end
    # Echoes the request back as JSON so POST specs can assert what was sent.
    @server.mount_proc("/echo") do |req, res|
      res.content_type = "application/json"
      res.body = JSON.generate(
        method: req.request_method,
        content_type: req.content_type,
        body: req.body,
        x_test: req["X-Test"]
      )
    end
    # Always answers 500, so POST specs can exercise the HTTP-error path.
    @server.mount_proc("/boom") do |_req, res|
      res.status = 500
      res.body = "boom"
    end
    @thread = Thread.new { @server.start }
    @port
  end

  def shutdown
    @server&.shutdown
    @thread&.join
  end

  def url(path = "/") = "http://127.0.0.1:#{@port}#{path}"

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end
end
