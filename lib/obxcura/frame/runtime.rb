# frozen_string_literal: true

module Obxcura
  class Frame
    # Runtime: executing JavaScript in the frame's context. This is the side that
    # reaches the Client and puts CDP commands on the wire; everything in DOM is
    # built on top of #evaluate.
    #
    # Ruby values cross into JS as real arguments (Runtime.callFunctionOn), not by
    # being string-interpolated into source. Node-handle resolution, cyclic-node
    # detection and a retry loop are deliberately left out.
    module Runtime
      # Evaluate a JS expression and return its value (awaits promises).
      #
      # Extra args are passed to the page as real values, reachable in the
      # expression as `arguments[0]`, `arguments[1]`, ... Without args it's a
      # single Runtime.evaluate (the hot path); with args it goes through
      # Runtime.callFunctionOn so nothing is interpolated into source.
      #
      # @param expression [String] the JS expression to evaluate.
      # @param args [Array] values passed to the page as `arguments[...]`.
      # @return [Object, nil] the evaluated value (JSON-decoded).
      # @raise [Obxcura::ProtocolError] if the JS throws.
      # @example
      #   frame.evaluate("arguments[0] + arguments[1]", 2, 3)   # => 5
      def evaluate(expression, *args)
        return handle_result(evaluate_command(expression)) if args.empty?

        evaluate_func("function() { return (#{expression}); }", *args)
      end

      # Call a JS function declaration with the given arguments, bound to the live
      # global object. Unlike {#evaluate}, `expression` is the function itself.
      #
      # @param expression [String] a JS function declaration.
      # @param args [Array] values passed to the function.
      # @param timeout [Integer, nil] override for the client's reply timeout.
      # @return [Object, nil] the function's return value (JSON-decoded).
      # @raise [Obxcura::ProtocolError] if the JS throws.
      # @example
      #   frame.evaluate_func("function(sel){ return document.querySelector(sel) }", "#id")
      def evaluate_func(expression, *args, timeout: nil)
        call_on(global_object_id, expression, args, timeout: timeout)
      end

      # Call a function declaration bound to a specific remote object (its `this`).
      # Used by {#evaluate_func} (bound to globalThis) and by {Node} reads (bound
      # to the node's handle).
      #
      # @param object_id [String] the CDP objectId to bind as `this`.
      # @param function_declaration [String] a JS function declaration.
      # @param args [Array] values passed to the function.
      # @param timeout [Integer, nil] override for the client's reply timeout,
      #   e.g. for a call that awaits a slow in-page POST.
      # @return [Object, nil] the function's return value (JSON-decoded).
      # @raise [Obxcura::ProtocolError] if the JS throws.
      def call_on(object_id, function_declaration, args = [], timeout: nil)
        handle_result(command(
          "Runtime.callFunctionOn",
          {
            functionDeclaration: function_declaration,
            objectId: object_id,
            arguments: args.map { |value| { value: value } },
            awaitPromise: true,
            returnByValue: true
          },
          timeout: timeout
        ))
      end

      private

      # objectId of the live global object, fetched fresh so it can't go stale
      # across navigations — no execution-context tracking needed.
      def global_object_id
        evaluate_command("globalThis", by_value: false).dig("result", "objectId")
      end

      def evaluate_command(expression, by_value: true)
        command("Runtime.evaluate", { expression: expression, awaitPromise: true, returnByValue: by_value })
      end

      def handle_result(result)
        if result["exceptionDetails"]
          raise ProtocolError, result.dig("exceptionDetails", "text") || "JS execution error"
        end

        result.dig("result", "value")
      end

      def command(method, params = {}, timeout: nil)
        options = { session_id: page.session_id }
        options[:timeout] = timeout if timeout
        page.client.command(method, params, **options)
      end
    end
  end
end
