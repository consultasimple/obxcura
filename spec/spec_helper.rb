# frozen_string_literal: true

require "obxcura"
Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  browser_available = ObscuraServer.available?

  config.before(:suite) do
    next unless browser_available

    ObscuraServer.boot
    TestSite.boot
  end

  config.after(:suite) do
    next unless browser_available

    TestSite.shutdown
    ObscuraServer.shutdown
  end

  config.around(:each, :obscura) do |example|
    if browser_available
      example.run
    else
      skip "Obscura binary not found — set OBSCURA_BIN or put `obscura` on PATH"
    end
  end
end
