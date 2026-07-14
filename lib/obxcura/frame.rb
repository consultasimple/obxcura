# frozen_string_literal: true

require_relative "frame/runtime"
require_relative "frame/dom"

module Obxcura
  # A browsing context inside a Page. It ties together Runtime (executing JS via
  # the Client) and DOM (reads built on that), and reaches the transport through
  # its owning Page — so a Frame never touches the Client directly except via
  # `page.client`.
  #
  # Obxcura drives a single main frame per page today (id == the page's
  # target_id); there is deliberately no iframe tree.
  class Frame
    include Runtime
    include DOM

    # @return [String] the frame's unique id (the page's CDP target_id).
    attr_accessor :id

    # @return [Obxcura::Page] the page that owns this frame.
    attr_reader :page

    # @param id [String] the frame id (its page's target_id).
    # @param page [Obxcura::Page] the owning page, used to reach the Client.
    def initialize(id, page)
      @id = id
      @page = page
    end

    # @return [String] the frame's current URL.
    def url
      evaluate("window.location.href")
    end

    # @return [String] the frame's current document title.
    def title
      evaluate("document.title")
    end
  end
end
