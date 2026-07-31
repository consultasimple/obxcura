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

    # Type text into this node with real key events, one character at a time —
    # Obscura implements `Input.dispatchKeyEvent`, so the browser itself performs
    # the insertion and fires `keydown`, `input` and `keyup` the way a keyboard
    # would. Focuses the node first, since key events go to the active element.
    # Appends, matching keyboard behaviour when the node already has text.
    #
    # Note `change` does *not* fire per keystroke — real browsers only fire it on
    # blur. The previous implementation synthesized both by assigning `value`
    # directly; listeners that relied on that `change` need to react to `input`.
    #
    # `Input.insertText` is still unimplemented in Obscura 0.1.11, so there is no
    # bulk-insert fast path: this costs two CDP round trips per character. Fine for
    # form fields (100 chars ≈ 40ms), but it is genuinely slower than the old
    # single-assignment approach — 500 chars ≈ 0.11s — so don't use it to stuff
    # large text through. Assign `value` via {Frame::Runtime#call_on} for that, and
    # accept that no key events fire.
    #
    # @param keys [Array<String>] text fragments to type (joined).
    # @return [self]
    def type(*keys)
      focus
      keys.join.each_char do |char|
        dispatch_key("keyDown", char, text: char)
        dispatch_key("keyUp", char)
      end
      self
    end

    # Submit this node's form. Works whether the node is the `<form>` itself or a
    # control inside one (resolved via `.form` / closest `<form>`).
    #
    # Always goes through `requestSubmit`, which follows the interactive path:
    # constraint validation runs and a cancelable `submit` event fires. There is no
    # fallback to `submit()` — as of Obscura 0.1.11 the two genuinely differ, with
    # `submit()` bypassing the submit event entirely, so falling back would quietly
    # skip both validation and any listener a caller registered.
    #
    # @return [self]
    # @raise [Obxcura::ProtocolError] if the node isn't a form or inside one.
    def submit
      result = @frame.call_on(remote_object_id, <<~JS)
        function() {
          const form = this.tagName === "FORM" ? this : (this.form || this.closest("form"));
          if (!form) return { error: "node is not a form and has no ancestor form" };
          form.requestSubmit();
        }
      JS
      raise ProtocolError, result["error"] if result.is_a?(Hash) && result["error"]

      self
    end

    # @return [String] the node's serialized outer HTML.
    def outer_html
      @frame.call_on(remote_object_id, "function() { return this.outerHTML; }")
    end

    private

    # `code` is deliberately left off: it describes a physical key, which we can't
    # infer from a character, and Obscura keys insertion off `text` anyway.
    def dispatch_key(type, char, text: nil)
      params = { type: type, key: char }
      params[:text] = text if text
      @frame.page.command("Input.dispatchKeyEvent", params)
    end
  end
end
