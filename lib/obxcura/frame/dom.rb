# frozen_string_literal: true

module Obxcura
  class Frame
    # DOM: high-level reads of the rendered page, all built on Runtime.
    #
    # Selector queries return live Nodes. Obscura serializes a DOM node over
    # returnByValue as an internal stub carrying an `_nid` — useless on its own,
    # but the `_nid` resolves (DOM.resolveNode) to a real remote object handle we
    # wrap in a Node and drive with Runtime#call_on.
    module DOM
      # @return [String] the current top-window URL.
      def current_url
        evaluate("window.location.href")
      end

      # @return [String] the current document title.
      def title
        evaluate("document.title")
      end

      # The live, post-JS HTML. Retrieved in chunks (see {Runtime#read_string})
      # because a full page's outerHTML routinely exceeds Obscura's message limit.
      # Aliased as `html`.
      #
      # @return [String] the rendered document's outer HTML.
      def body
        read_string("document.documentElement.outerHTML")
      end
      alias_method :html, :body

      # First element matching a CSS selector.
      #
      # @param selector [String] a CSS selector.
      # @return [Obxcura::Node, nil] the matching node, or nil if none.
      def at_css(selector)
        to_node(evaluate_func("function(s) { return document.querySelector(s); }", selector))
      end

      # All elements matching a CSS selector.
      #
      # @param selector [String] a CSS selector.
      # @return [Array<Obxcura::Node>] the matching nodes (empty if none).
      def css(selector)
        Array(evaluate_func("function(s) { return Array.from(document.querySelectorAll(s)); }", selector))
          .filter_map { |stub| to_node(stub) }
      end

      private

      # Resolve Obscura's serialized node stub ({"_nid"=>N,...}) into a Node.
      #
      # @param stub [Hash, nil] the serialized node from a querySelector call.
      # @return [Obxcura::Node, nil] a live node handle, or nil for a blank match.
      def to_node(stub)
        return nil unless stub.is_a?(Hash) && stub["_nid"]

        object_id = command("DOM.resolveNode", { nodeId: stub["_nid"] }).dig("object", "objectId")

        Node.new(self, object_id)
      end
    end
  end
end
