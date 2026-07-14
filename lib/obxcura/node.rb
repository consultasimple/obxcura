# frozen_string_literal: true

module Obxcura
  # A live handle to a DOM node inside a Frame. Backed by a CDP remote object, so
  # reads run as function calls bound to that object and reflect the current DOM.
  # Returned by Frame::DOM#at_css / #css.
  class Node
    # @return [String] the CDP remote objectId backing this node.
    attr_reader :object_id

    # @param frame [Obxcura::Frame] the frame the node lives in.
    # @param object_id [String] the CDP objectId of the node.
    def initialize(frame, object_id)
      @frame = frame
      @object_id = object_id
    end

    # @return [String] the visible text of the node and its descendants.
    def text
      @frame.call_on(@object_id, "function() { return this.textContent; }")
    end

    # Read an attribute value.
    #
    # @param name [String] the attribute name.
    # @return [String, nil] the attribute value, or nil if absent.
    def [](name)
      @frame.call_on(@object_id, "function(name) { return this.getAttribute(name); }", [ name ])
    end

    # @return [String] the node's serialized outer HTML.
    def outer_html
      @frame.call_on(@object_id, "function() { return this.outerHTML; }")
    end
  end
end
