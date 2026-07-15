# frozen_string_literal: true

require "socket"
require "openssl"
require "websocket/driver"

module Obxcura
  # The CDP transport: a single WebSocket to the browser endpoint.
  #
  # Built directly on websocket-driver, because the higher-level
  # websocket-client-simple reads the socket one byte at a time (`@socket.getc`)
  # — a ~1MB CDP frame there takes seconds and can wedge the read loop. Here a
  # single reader thread pumps raw bytes through the driver (`readpartial` +
  # `driver.parse`), which parses frames efficiently.
  #
  # This object *is* the driver's I/O adapter: websocket-driver calls #url for the
  # handshake and #write to put bytes on the wire.
  #
  # Everything on the wire is multiplexed over this one socket. Command replies
  # come back keyed by the `id` we assigned (globally unique across the
  # connection), so we resolve those regardless of session. Events instead carry
  # a `sessionId`, so we fan them out to whichever Page subscribed for that
  # session. Browser-level events (no sessionId) go to the `:browser` slot.
  class Client
    # @return [Integer] default seconds to wait for a command reply.
    DEFAULT_TIMEOUT = 30

    # Obscura frames stay well under this; it's just a guard against a runaway
    # allocation — a sane cap on the receive size.
    #
    # @return [Integer] largest CDP frame (bytes) the driver will assemble.
    MAX_MESSAGE_SIZE = 64 * 1024 * 1024

    # Bytes pulled per read syscall. Small is fine — the driver reassembles
    # frames across reads; this only bounds how much we buffer at once.
    #
    # @return [Integer]
    READ_CHUNK = 512

    # @return [String] the WebSocket URL of the browser endpoint.
    attr_reader :url

    # Open the WebSocket to the browser and block until the handshake completes.
    #
    # @param url [String] the `ws://`/`wss://` browser endpoint.
    # @param timeout [Integer] default seconds to wait for command replies.
    # @raise [Obxcura::TimeoutError] if the connection can't be established.
    def initialize(url, timeout: DEFAULT_TIMEOUT)
      @url = url
      @timeout = timeout
      @command_id = 0
      @mutex = Mutex.new
      @write_mutex = Mutex.new
      @pending = {}
      @subscribers = {}
      @open = Queue.new
      connect
    end

    # Send a CDP command and block until its reply arrives.
    #
    # @param method [String] the CDP method name, e.g. "Runtime.evaluate".
    # @param params [Hash] the method parameters.
    # @param session_id [String, nil] nil sends a browser-level command (target
    #   management); a session id routes it to a specific page.
    # @param timeout [Integer] seconds to wait for the reply.
    # @return [Hash] the command's `result` object.
    # @raise [Obxcura::TimeoutError] if no reply arrives in time.
    # @raise [Obxcura::ProtocolError] if the browser returns an error.
    def command(method, params = {}, session_id: nil, timeout: @timeout)
      id = next_id
      queue = Queue.new
      @mutex.synchronize { @pending[id] = queue }

      frame = { id: id, method: method, params: params }
      frame[:sessionId] = session_id if session_id
      @driver.text(JSON.generate(frame))

      message = Timeout.timeout(timeout, TimeoutError, "#{method} timed out after #{timeout}s") { queue.pop }
      raise ProtocolError, message["error"]["message"] if message["error"]

      message["result"]
    ensure
      @mutex.synchronize { @pending.delete(id) }
    end

    # Register a handler for events on a given session.
    #
    # @param session_id [String, Symbol] the page session id, or `:browser` for
    #   target-level (session-less) events.
    # @yieldparam method [String] the CDP event name.
    # @yieldparam params [Hash] the event parameters.
    # @return [Proc] the stored handler.
    def subscribe(session_id, &block)
      @subscribers[session_id] = block
    end

    # Remove the handler previously registered for a session.
    #
    # @param session_id [String, Symbol] the session to stop listening on.
    # @return [Proc, nil] the removed handler, if any.
    def unsubscribe(session_id)
      @subscribers.delete(session_id)
    end

    # Close the driver, socket and reader thread. Safe to call more than once.
    #
    # @return [void]
    def close
      @closing = true
      @driver&.close
      @socket&.close
      @subscribers.clear
      @reader&.kill
    rescue IOError, SystemCallError
      nil
    end

    # @return [Boolean] whether the connection is being (or has been) torn down.
    def closing?
      @closing == true
    end

    # I/O adapter for websocket-driver: puts outgoing bytes on the wire. Writes
    # are serialized so command threads and the driver's own control frames
    # (ping/pong/close) never interleave and corrupt the stream.
    #
    # @param data [String] raw bytes to write.
    # @return [void]
    def write(data)
      @write_mutex.synchronize { @socket.write(data) }
    rescue IOError, SystemCallError => e
      warn "[Obxcura] websocket write error: #{e}" unless closing?
    end

    private

    def connect
      @socket = open_socket
      @driver = ::WebSocket::Driver.client(self, max_length: MAX_MESSAGE_SIZE)

      @driver.on(:open) { @open.push(true) }
      @driver.on(:message) { |event| handle_message(event.data) }
      @driver.on(:close) { |event| handle_disconnect(event) }
      @driver.on(:error) { |event| warn "[Obxcura] websocket error: #{event.message}" unless closing? }

      start_reader
      @driver.start

      Timeout.timeout(@timeout, TimeoutError, "Could not connect to #{@url}") { @open.pop }
    end

    def open_socket
      uri = URI(@url)
      tcp = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))
      return tcp unless uri.scheme == "wss"

      ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new)
      ssl.sync_close = true
      ssl.hostname = uri.host
      ssl.connect
      ssl
    end

    # One reader thread feeds raw bytes to the driver, which emits :message as
    # frames complete. A raised parse is logged (not fatal); a dead socket ends
    # the loop and wakes any in-flight commands so they don't hang to timeout.
    def start_reader
      @reader = Thread.new do
        until closing?
          begin
            @driver.parse(@socket.readpartial(READ_CHUNK))
          rescue EOFError, IOError, SystemCallError => e
            handle_disconnect(e) unless closing?
            break
          rescue StandardError => e
            warn "[Obxcura] reader error: #{e}" unless closing?
          end
        end
      end
    end

    def handle_message(data)
      message = JSON.parse(data)

      if message["id"]
        queue = @mutex.synchronize { @pending[message["id"]] }
        queue&.push(message)
      elsif message["method"]
        handler = @subscribers[message["sessionId"] || :browser]
        handler&.call(message["method"], message["params"])
      end
    rescue JSON::ParserError => e
      warn "[Obxcura] dropped unparseable message: #{e}" unless closing?
    end

    # The socket dropped (or the browser closed us). Fail every waiting command
    # so callers get a prompt error instead of a 30s timeout.
    def handle_disconnect(reason)
      description = reason.respond_to?(:message) ? reason.message : reason.to_s
      @mutex.synchronize do
        @pending.each_value { |queue| queue.push({ "error" => { "message" => "connection closed: #{description}" } }) }
      end
    end

    def next_id
      @mutex.synchronize { @command_id += 1 }
    end
  end
end
