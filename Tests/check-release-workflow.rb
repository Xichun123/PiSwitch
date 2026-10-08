#!/usr/bin/env ruby
# Executes the workflow's real shell steps with local git/gh mocks; never publishes.
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'

ROOT = File.expand_path('..', __dir__)
WORKFLOW = YAML.safe_load(File.read(File.join(ROOT, '.github/workflows/release.yml')))
PREPARE = WORKFLOW.fetch('jobs').fetch('prepare')
RELEASE = WORKFLOW.fetch('jobs').fetch('release')
SHA = 'a' * 40
OTHER_SHA = 'b' * 40
ARCH = Open3.capture2('uname', '-m').first.strip
DMG = ".build/release-v0.1.2/PiSwitch-v0.1.2-macos-#{ARCH}.dmg"
SUMS = '.build/release-v0.1.2/SHA256SUMS.txt'

GH_MOCK = <<~'RUBY'
  #!/usr/bin/env ruby
  require 'json'
  File.open(ENV.fetch('MOCK_LOG'), 'a') { |f| f.puts(JSON.generate(ARGV)) }
  if ARGV.first == 'api'
    if ARGV.any? { |arg| arg.include?('/commits/refs/tags/') }
      exit 22 if ENV['MOCK_TAG_ERROR'] == '1'
      puts ENV.fetch('MOCK_SHA')
    elsif ARGV.any? { |arg| arg.end_with?('/releases') }
      exit 23 if ENV['MOCK_RELEASES_ERROR'] == '1'
      puts ENV.fetch('MOCK_RELEASE_TAGS', '')
    else
      abort "Unexpected API request: #{ARGV.inspect}"
    end
  elsif ARGV[0, 2] == ['release', 'create']
    abort 'Missing --verify-tag' unless ARGV.include?('--verify-tag')
    exit 24 if ENV['MOCK_CREATE_ERROR'] == '1'
    File.write(ENV.fetch('MOCK_MUTATION'), 'create')
  elsif ARGV[0, 2] == ['release', 'upload']
    exit 25 if ENV['MOCK_UPLOAD_ERROR'] == '1'
    File.write(ENV.fetch('MOCK_MUTATION'), 'upload')
  else
    abort "Unexpected gh command: #{ARGV.inspect}"
  end
RUBY

GIT_MOCK = <<~'RUBY'
  #!/usr/bin/env ruby
  abort "Unexpected git command: #{ARGV.inspect}" unless ARGV == ['rev-parse', 'HEAD']
  puts ENV.fetch('MOCK_HEAD')
RUBY

PACKAGE_MOCK = <<~'BASH'
  #!/bin/bash
  set -euo pipefail
  if [[ $# != 1 || "$1" != "$RELEASE_VERSION" || "${MOCK_PACKAGE_ERROR:-0}" == 1 ]]; then
    exit 1
  fi
  out=".build/release-v$1"
  mkdir -p "$out"
  printf 'packaged version %s\n' "$1" > "$out/PiSwitch-v$1-macos-$(uname -m).dmg"
BASH

def check(condition, message)
  raise message unless condition
end

def step(job, name)
  job.fetch('steps').find { |entry| entry['name'] == name } || raise("Missing step: #{name}")
end

def execute(entry, overrides = {})
  Dir.mktmpdir('release-workflow-test-') do |dir|
    bin = File.join(dir, 'bin')
    FileUtils.mkdir_p([bin, File.join(dir, 'scripts'), File.dirname(File.join(dir, DMG))])
    {'gh' => GH_MOCK, 'git' => GIT_MOCK}.each do |name, body|
      path = File.join(bin, name)
      File.write(path, body)
      FileUtils.chmod(0755, path)
    end
    File.write(File.join(dir, 'scripts/package-release.sh'), PACKAGE_MOCK)
    File.write(File.join(dir, DMG), 'fixture DMG')
    hash = Digest::SHA256.file(File.join(dir, DMG)).hexdigest
    File.write(File.join(dir, SUMS), "#{hash}  #{File.basename(DMG)}\n")
    output = File.join(dir, 'output')
    log = File.join(dir, 'gh.log')
    mutation = File.join(dir, 'mutation')
    File.write(output, '')
    env = {
      'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
      'GH_TOKEN' => 'local-test-token', 'GH_REPO' => 'example/PiSwitch',
      'EVENT_NAME' => 'workflow_dispatch', 'RELEASE_INPUT' => 'v0.1.2',
      'EVENT_TAG' => 'main', 'EVENT_SHA' => OTHER_SHA,
      'RELEASE_TAG' => 'v0.1.2', 'RELEASE_VERSION' => '0.1.2', 'RELEASE_SHA' => SHA,
      'DMG_PATH' => DMG, 'CHECKSUMS_PATH' => SUMS,
      'GITHUB_OUTPUT' => output, 'MOCK_LOG' => log, 'MOCK_MUTATION' => mutation,
      'MOCK_SHA' => SHA, 'MOCK_HEAD' => SHA,
      'MOCK_TAG_ERROR' => '0', 'MOCK_RELEASES_ERROR' => '0',
      'MOCK_CREATE_ERROR' => '0', 'MOCK_UPLOAD_ERROR' => '0',
      'MOCK_PACKAGE_ERROR' => '0', 'MOCK_RELEASE_TAGS' => ''
    }.merge(overrides)
    yield dir if block_given?
    stdout, stderr, status = Open3.capture3(env, 'bash', '-euo', 'pipefail', '-c', entry.fetch('run'), chdir: dir)
    {
      success: status.success?, stdout: stdout, stderr: stderr,
      outputs: File.read(output).lines.to_h { |line| line.chomp.split('=', 2) },
      calls: File.exist?(log) ? File.readlines(log).map { |line| JSON.parse(line) } : [],
      mutation: File.exist?(mutation) ? File.read(mutation) : nil,
      injected: File.exist?(File.join(dir, 'injected'))
    }
  end
end

def succeeded(result)
  check(result[:success], "Expected success:\n#{result[:stdout]}\n#{result[:stderr]}")
end

def rejected(result)
  check(!result[:success], "Expected rejection: #{result.inspect}")
  check(result[:mutation].nil?, 'Rejected request changed release assets')
  check(!result[:injected], 'Untrusted input executed a shell command')
end

count = 0
run_test = lambda do |name, &body|
  body.call
  count += 1
  puts "PASS: #{name}"
end
resolve = step(PREPARE, 'Resolve release target')
verify = step(RELEASE, 'Verify checked-out commit')
package = step(RELEASE, 'Package DMG')
publish = step(RELEASE, 'Publish GitHub Release')

run_test.call('workflow binds checkout, permissions, and serialization to the resolved target') do
  check(WORKFLOW['permissions'] == {'contents' => 'read'}, 'Preparation must be read-only')
  check(RELEASE['permissions'] == {'contents' => 'write'}, 'Publishing needs contents: write')
  check(RELEASE['needs'] == 'prepare', 'Publishing must depend on validation')
  events = WORKFLOW['on'] || WORKFLOW[true]
  check(events.fetch('push').fetch('tags') == ['v*'], 'Only version tags should trigger automatic releases')
  check(events.fetch('workflow_dispatch').fetch('inputs').fetch('tag')['required'] == true, 'Manual release target must be required')
  check(PREPARE['outputs'] == {
    'tag' => '${{ steps.target.outputs.tag }}',
    'version' => '${{ steps.target.outputs.version }}',
    'sha' => '${{ steps.target.outputs.sha }}'
  }, 'Target outputs are not wired to the resolver')
  checkout = step(RELEASE, 'Checkout release commit')
  check(checkout.fetch('with')['ref'] == '${{ needs.prepare.outputs.sha }}', 'Checkout must use immutable commit SHA')
  check(checkout.fetch('with')['persist-credentials'] == false, 'Checkout must not persist write credentials')
  check(RELEASE['env'] == {
    'RELEASE_TAG' => '${{ needs.prepare.outputs.tag }}',
    'RELEASE_VERSION' => '${{ needs.prepare.outputs.version }}',
    'RELEASE_SHA' => '${{ needs.prepare.outputs.sha }}'
  }, 'Build and publish must share the validated target')
  check(RELEASE['concurrency'] == {
    'group' => 'release-${{ needs.prepare.outputs.tag }}', 'cancel-in-progress' => false
  }, 'Both input spellings must serialize on the canonical tag')
  check(PREPARE['steps'].index(step(PREPARE, 'Test release workflow')) < PREPARE['steps'].index(resolve), 'Regression tests must precede target resolution')
  check(step(PREPARE, 'Test release workflow')['run'] == 'ruby Tests/check-release-workflow.rb', 'Regression suite is not connected to CI')
  ordered_steps = ['Checkout release commit', 'Verify checked-out commit', 'Run test suite', 'Package DMG', 'Publish GitHub Release']
  positions = ordered_steps.map { |name| RELEASE['steps'].index(step(RELEASE, name)) }
  check(positions == positions.sort && positions.uniq == positions, 'Verification, tests, and packaging must precede publishing')
end

run_test.call('all shell steps use environment variables, never expression interpolation') do
  WORKFLOW.fetch('jobs').each_value do |job|
    job.fetch('steps').each do |entry|
      next unless entry['run']
      check(!entry['run'].include?('${{'), "Expression interpolated into #{entry['name']}")
      _, stderr, status = Open3.capture3('bash', '-n', stdin_data: entry['run'])
      check(status.success?, "Invalid shell in #{entry['name']}: #{stderr}")
    end
  end
  check(resolve.fetch('env')['RELEASE_INPUT'] == '${{ inputs.tag }}', 'Manual input must travel via env')
  check(publish.fetch('env')['DMG_PATH'] == '${{ steps.package.outputs.dmg }}', 'Artifact path must travel via env')
  check(publish.fetch('env')['CHECKSUMS_PATH'] == '${{ steps.package.outputs.checksums }}', 'Checksum path must travel via env')
end

['v0.1.2', '0.1.2', 'v123.456.789'].each do |input|
  run_test.call("manual version #{input} resolves an existing tag, not main") do
    result = execute(resolve, 'RELEASE_INPUT' => input)
    succeeded(result)
    version = input.sub(/^v/, '')
    check(result[:outputs] == {'tag' => "v#{version}", 'version' => version, 'sha' => SHA}, 'Wrong normalized target')
    check(result[:calls] == [['api', "repos/example/PiSwitch/commits/refs/tags/v#{version}", '--jq', '.sha']], 'Resolver did not request the exact tag')
  end
end

run_test.call('push releases the triggering tag commit') do
  result = execute(resolve, 'EVENT_NAME' => 'push', 'EVENT_TAG' => 'v0.1.2', 'EVENT_SHA' => SHA, 'RELEASE_INPUT' => 'ignored')
  succeeded(result)
  check(result[:outputs]['sha'] == SHA && result[:outputs]['tag'] == 'v0.1.2', 'Wrong push target')
end

['', 'main', 'v1.2', 'v1.2.3-beta', 'vv1.2.3', '../1.2.3', "v1.2.3\nsha=bad",
 'v0.1.2$(touch injected)', 'v0.1.2`touch injected`', 'v0.1.2"; touch injected; #'].each do |input|
  run_test.call("reject invalid or malicious manual input #{input.inspect} before network access") do
    result = execute(resolve, 'RELEASE_INPUT' => input)
    rejected(result)
    check(result[:calls].empty? && result[:outputs].empty?, 'Invalid input reached API or outputs')
  end
end

run_test.call('push cannot silently normalize an unprefixed tag') do
  result = execute(resolve, 'EVENT_NAME' => 'push', 'EVENT_TAG' => '0.1.2', 'EVENT_SHA' => SHA)
  rejected(result)
  check(result[:calls].empty?, 'Invalid push tag reached API')
end

run_test.call('malicious push tag is rejected without shell execution') do
  result = execute(resolve, 'EVENT_NAME' => 'push', 'EVENT_TAG' => 'v0.1.2$(touch injected)', 'EVENT_SHA' => SHA)
  rejected(result)
  check(result[:calls].empty? && result[:outputs].empty?, 'Malicious tag reached API or outputs')
end

run_test.call('unsupported events fail closed') do
  result = execute(resolve, 'EVENT_NAME' => 'pull_request')
  rejected(result)
  check(result[:calls].empty?, 'Unsupported event reached API')
end

run_test.call('missing tags and API errors do not emit a release target') do
  result = execute(resolve, 'MOCK_TAG_ERROR' => '1')
  rejected(result)
  check(result[:outputs].empty?, 'Failed lookup emitted outputs')
end

['', 'not-a-sha', 'a' * 39, "#{SHA}\n#{OTHER_SHA}"].each do |sha|
  run_test.call("reject invalid API commit #{sha.inspect}") do
    result = execute(resolve, 'MOCK_SHA' => sha)
    rejected(result)
    check(result[:outputs].empty?, 'Invalid SHA emitted outputs')
  end
end

run_test.call('a moved push tag cannot build a different commit') do
  result = execute(resolve, 'EVENT_NAME' => 'push', 'EVENT_TAG' => 'v0.1.2', 'EVENT_SHA' => OTHER_SHA)
  rejected(result)
  check(result[:outputs].empty?, 'Moved tag emitted outputs')
end

run_test.call('checked-out commit is verified before building') do
  succeeded(execute(verify))
  rejected(execute(verify, 'MOCK_HEAD' => OTHER_SHA))
end

run_test.call('packaging uses the normalized version and emits actual artifact paths') do
  result = execute(package)
  succeeded(result)
  check(result[:outputs] == {'dmg' => DMG, 'checksums' => SUMS}, 'Wrong artifact paths')
end

run_test.call('packaging failure emits no artifacts for publishing') do
  result = execute(package, 'MOCK_PACKAGE_ERROR' => '1')
  rejected(result)
  check(result[:outputs].empty?, 'Failed packaging emitted outputs')
end

run_test.call('new release requires an existing tag and records the exact commit') do
  result = execute(publish)
  succeeded(result)
  check(result[:mutation] == 'create', 'Release was not created')
  create = result[:calls].find { |args| args[0, 2] == ['release', 'create'] }
  check(create == ['release', 'create', 'v0.1.2', DMG, SUMS, '--verify-tag', '--target', SHA, '--title', 'PiSwitch v0.1.2', '--generate-notes'], 'Unsafe release creation arguments')
end

run_test.call('existing release uploads only after checking the tag and checksum') do
  result = execute(publish, 'MOCK_RELEASE_TAGS' => "v0.1.0\nv0.1.2\nv0.1.3")
  succeeded(result)
  check(result[:mutation] == 'upload', 'Existing release was not updated')
  check(result[:calls].last == ['release', 'upload', 'v0.1.2', DMG, SUMS, '--clobber'], 'Wrong upload target')
end

run_test.call('release lookup matches the complete tag, not a prefix') do
  result = execute(publish, 'MOCK_RELEASE_TAGS' => "v0.1.20\nv0.1.21")
  succeeded(result)
  check(result[:mutation] == 'create', 'A different release was mistaken for this tag')
end

[
  ['checked-out commit changed', {'MOCK_HEAD' => OTHER_SHA}],
  ['tag moved during build', {'MOCK_SHA' => OTHER_SHA}],
  ['tag deleted or lookup failed', {'MOCK_TAG_ERROR' => '1'}],
  ['release listing failed', {'MOCK_RELEASES_ERROR' => '1'}]
].each do |name, overrides|
  run_test.call("publishing stops without remote writes when #{name}") do
    result = execute(publish, overrides)
    rejected(result)
    check(result[:calls].none? { |args| args.first == 'release' }, 'Failure reached release mutation command')
  end
end

run_test.call('modified DMG cannot be published with stale checksums') do
  result = execute(publish) { |dir| File.write(File.join(dir, DMG), 'tampered') }
  rejected(result)
  check(result[:calls].none? { |args| args.first == 'release' }, 'Corrupt artifact reached upload')
end

run_test.call('missing checksum file prevents publishing') do
  result = execute(publish) { |dir| File.delete(File.join(dir, SUMS)) }
  rejected(result)
  check(result[:calls].none? { |args| args.first == 'release' }, 'Missing checksum reached upload')
end

run_test.call('create and upload errors are not swallowed or retried as another operation') do
  rejected(execute(publish, 'MOCK_CREATE_ERROR' => '1'))
  rejected(execute(publish, 'MOCK_RELEASE_TAGS' => 'v0.1.2', 'MOCK_UPLOAD_ERROR' => '1'))
end

puts "PASS: #{count} release workflow checks (no network or real release writes)"
