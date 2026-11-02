#!/usr/bin/env ruby
# Exercise the workflow's actual shell guard without invoking a compiler.
require 'yaml'
require 'open3'

workflow = YAML.load_file(File.expand_path('../workflows/build.yml', __dir__))
steps = workflow.fetch('jobs').fetch('build-and-test').fetch('steps')
guard = steps.find { |step| ['Verify Swift version', 'Show toolchain'].include?(step['name']) }
abort 'Missing Swift version step' unless guard

stub = <<~BASH
  swift() {
    if [[ "$*" != "--version" ]]; then
      return 99
    fi
    printf '%s\\n' "$STUB_SWIFT_OUTPUT"
    return "$STUB_SWIFT_STATUS"
  }
BASH

cases = [
  ['Apple Swift 6.4', 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1)', 0, 0],
  ['Apple Swift 6.4.1', 'Apple Swift version 6.4.1 (swiftlang-6.4.1.1)', 0, 0],
  ['driver-prefixed Swift 6.4',
   "swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1)\nTarget: arm64-apple-macosx27.0.0", 0, 0],
  ['Swift 6.3', 'Apple Swift version 6.3 (swiftlang-6.3.0.1)', 0, 1],
  ['Swift 6.5', 'Apple Swift version 6.5 (swiftlang-6.5.0.1)', 0, 1],
  ['Swift 6.40', 'Apple Swift version 6.40 (swiftlang-6.40.0.1)', 0, 1],
  ['Swift 6.40.1', 'Apple Swift version 6.40.1 (swiftlang-6.40.1.1)', 0, 1],
  ['empty version', '', 0, 1],
  ['compiler failure', '', 42, 42],
  ['compiler failure with matching output', 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1)', 42, 42]
]

failures = []
cases.each do |name, output, compiler_status, expected_status|
  stdout, stderr, status = Open3.capture3(
    { 'STUB_SWIFT_OUTPUT' => output, 'STUB_SWIFT_STATUS' => compiler_status.to_s },
    '/bin/bash', '-e', '-o', 'pipefail', '-c', stub + guard.fetch('run')
  )
  if status.exitstatus != expected_status
    failures << "#{name}: expected exit #{expected_status}, got #{status.exitstatus}\n#{stdout}#{stderr}"
  elsif expected_status.zero? && !stdout.include?(output)
    failures << "#{name}: compiler version was not printed"
  else
    puts "PASS: #{name}"
  end
end

abort failures.join("\n") unless failures.empty?
puts "All #{cases.length} Swift version guard cases passed."
