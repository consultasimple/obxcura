# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"
require "yard"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

# `rake doc` renders the YARD docs into doc/ (gitignored).
YARD::Rake::YardocTask.new(:doc) do |t|
  t.files = [ "lib/**/*.rb" ]
end

task default: %i[rubocop spec]
