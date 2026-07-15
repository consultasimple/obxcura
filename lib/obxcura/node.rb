# frozen_string_literal: true

module Obxcura
  # A live handle to a DOM node inside a Frame. Backed by a CDP remote object, so
  # reads run as function calls bound to that object and reflect the current DOM.
  # Returned by Frame::DOM#at_css / #css.
  class Node
    # @return [String] the CDP remote objectId backing this node. Named
    # `remote_object_id` (not `object_id`) so it doesn't shadow Ruby's
    # `Object#object_id`, which every object relies on for identity.
    attr_reader :remote_object_id

    # @param frame [Obxcura::Frame] the frame the node lives in.
    # @param object_id [String] the CDP objectId of the node.
    def initialize(frame, object_id)
      @frame = frame
      @remote_object_id = object_id
    end

    # @return [String] the visible text of the node and its descendants.
    def text
      @frame.call_on(remote_object_id, "function() { return this.textContent; }")
    end

    # @return [String, nil] the node's `value` (form controls), or nil.
    def value
      @frame.call_on(remote_object_id, "function() { return this.value; }")
    end

    # First descendant matching a CSS selector, searched within this node.
    #
    # @param selector [String] a CSS selector.
    # @return [Obxcura::Node, nil] the matching node, or nil if none.
    def at_css(selector)
      @frame.to_node(@frame.call_on(remote_object_id, "function(s) { return this.querySelector(s); }", [ selector ]))
    end

    # Read an attribute value.
    #
    # @param name [String] the attribute name.
    # @return [String, nil] the attribute value, or nil if absent.
    def [](name)
      @frame.call_on(remote_object_id, "function(name) { return this.getAttribute(name); }", [ name ])
    end
    alias attribute []

    # Give this node keyboard focus.
    #
    # @return [self]
    def focus
      tap { @frame.page.command("DOM.focus", objectId: remote_object_id) }
    end

    # Type text into this node. Obscura has no Input domain (Input.insertText /
    # dispatchKeyEvent are unimplemented), so this sets `value` in page context
    # and fires the `input`/`change` events real typing would, letting listeners
    # react. Appends, matching keyboard behaviour when the node already has text.
    #
    # @param keys [Array<String>] text fragments to type (joined).
    # @return [self]
    def type(*keys)
      tap { @frame.call_on(remote_object_id, <<~JS, [ keys.join ])
        function(text) {
          this.value = (this.value || "") + text;
          this.dispatchEvent(new Event("input", { bubbles: true }));
          this.dispatchEvent(new Event("change", { bubbles: true }));
        }
      JS
      }
    end

    # Submit this node's form. Works whether the node is the `<form>` itself or a
    # control inside one (resolved via `.form` / closest `<form>`). Prefers
    # `requestSubmit` (runs validation and fires the submit event) and falls back
    # to `submit` where it's unavailable.
    #
    # @return [self]
    # @raise [Obxcura::ProtocolError] if the node isn't a form or inside one.
    def submit
      result = @frame.call_on(remote_object_id, <<~JS)
        function() {
          const form = this.tagName === "FORM" ? this : (this.form || this.closest("form"));
          if (!form) return { error: "node is not a form and has no ancestor form" };
          form.requestSubmit ? form.requestSubmit() : form.submit();
        }
      JS
      raise ProtocolError, result["error"] if result.is_a?(Hash) && result["error"]

      self
    end

    # @return [String] the node's serialized outer HTML.
    def outer_html
      @frame.call_on(remote_object_id, "function() { return this.outerHTML; }")
    end
  end
end
