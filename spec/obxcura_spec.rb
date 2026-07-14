# frozen_string_literal: true

RSpec.describe Obxcura do
  it "exposes a version" do
    expect(Obxcura::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "defines an error hierarchy" do
    expect(Obxcura::TimeoutError.ancestors).to include(Obxcura::Error)
    expect(Obxcura::ProtocolError.ancestors).to include(Obxcura::Error)
    expect(Obxcura::ConnectionError.ancestors).to include(Obxcura::Error)
  end
end
