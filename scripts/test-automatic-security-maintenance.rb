require 'minitest/autorun'
require_relative 'automatically-maintain-dependabot-security-updates'

class AutomaticSecurityMaintenanceTest < Minitest::Test
  Policy = AutomaticSecurityMaintenance
  HEAD = 'a' * 40
  BASE = 'b' * 40
  MERGE = 'c' * 40

  def pr
    { 'user' => { 'login' => 'dependabot[bot]', 'type' => 'Bot' }, 'state' => 'open', 'draft' => false,
      'head' => { 'sha' => HEAD, 'repo' => { 'full_name' => Policy::REPOSITORY } },
      'base' => { 'sha' => BASE, 'ref' => 'main', 'repo' => { 'full_name' => Policy::REPOSITORY } } }
  end

  def commits
    [{ 'author' => { 'login' => 'dependabot[bot]' }, 'commit' => { 'verification' => { 'verified' => true } } }]
  end

  def checks
    Policy::REQUIRED_CHECKS.map { |name| { 'name' => name, 'bucket' => 'pass' } }
  end

  def workflow(version, sha = HEAD, command = 'true')
    "jobs:\n  check:\n    steps:\n      - uses: example/action@#{sha} # v#{version}\n      - run: '#{command}'\n"
  end

  def lock(version, sha)
    JSON.generate('version' => 3, 'pins' => [{ 'kind' => 'remoteSourceControl', 'location' => 'https://github.com/example/package.git', 'state' => { 'revision' => sha, 'version' => version } }])
  end

  def lookup
    ->(queries) { queries.any? { |query| query['version'] == '1.0.0' } ? ['GHSA-SYNTHETIC-TEST'] : [] }
  end

  def test_only_verified_bot_commits_from_same_repository_and_exact_head
    assert Policy.eligible_identity?(pr, commits, HEAD)
    refute Policy.eligible_identity?(pr, commits, BASE)
    refute Policy.eligible_identity?(pr.merge('user' => { 'login' => 'human', 'type' => 'User' }), commits, HEAD)
    refute Policy.eligible_identity?(pr.merge('head' => { 'sha' => HEAD, 'repo' => { 'full_name' => 'other/repo' } }), commits, HEAD)
    refute Policy.eligible_identity?(pr, commits + [{ 'author' => { 'login' => 'human' } }], HEAD)
    refute Policy.eligible_identity?(pr, [{ 'author' => { 'login' => 'dependabot[bot]' }, 'commit' => { 'verification' => { 'verified' => false } } }], HEAD)
  end

  def test_every_required_and_additional_check_must_pass
    assert Policy.all_checks_pass?(checks)
    refute Policy.all_checks_pass?(checks.first(1))
    refute Policy.all_checks_pass?(checks + [{ 'name' => 'extra', 'bucket' => 'pending' }])
    refute Policy.all_checks_pass?(checks + [{ 'name' => 'extra', 'bucket' => 'fail' }])
    assert Policy.all_checks_pass?(checks + [{ 'name' => 'tag-release-only', 'bucket' => 'skipping' }])
  end

  def test_source_changes_and_workflow_creation_are_not_automatically_merged
    refute Policy.allowed_files?([{ 'filename' => 'Sources/NetworkCulprit/App.swift', 'status' => 'modified' }])
    refute Policy.allowed_files?([{ 'filename' => '.github/workflows/new.yml', 'status' => 'added' }])
    assert Policy.allowed_files?([{ 'filename' => 'Package.resolved', 'status' => 'modified' }])
  end

  def test_ci_security_fix_merges_without_app_release
    result = Policy.classify({ '.github/workflows/check.yml' => [workflow('1.0.0', BASE), workflow('1.0.1')] }, lookup: lookup)
    assert result['security_fix']
    refute result['app_changed']
  end

  def test_swift_security_fix_requires_an_app_release
    result = Policy.classify({ 'Package.resolved' => [lock('1.0.0', BASE), lock('1.0.1', HEAD)] }, lookup: lookup)
    assert result['security_fix']
    assert result['app_changed']
  end

  def test_routine_update_does_not_become_a_security_update
    result = Policy.classify({ 'Package.resolved' => [lock('1.0.1', BASE), lock('1.0.2', HEAD)] }, lookup: lookup)
    refute result['security_fix']
  end

  def test_workflow_permission_or_command_changes_are_rejected
    assert_raises(RuntimeError) do
      Policy.classify({ '.github/workflows/check.yml' => [workflow('1.0.0', BASE), workflow('1.0.1', HEAD, 'false')] }, lookup: lookup)
    end
  end

  def test_unfixed_advisories_and_lookup_errors_stop_automation
    change = { 'Package.resolved' => [lock('1.0.0', BASE), lock('1.0.1', HEAD)] }
    assert_raises(RuntimeError) { Policy.classify(change, lookup: ->(_) { ['GHSA-STILL-VULNERABLE'] }) }
    assert_raises(IOError) { Policy.classify(change, lookup: ->(_) { raise IOError, 'unavailable' }) }
  end

  class FakeClient < Policy::Client
    attr_reader :writes, :releases
    def initialize(pr:, commits:, checks:, files:, contents:, lookup:, dry_run: false)
      super(lookup: lookup, dry_run: dry_run)
      @pr, @commits, @checks, @files, @contents = pr, commits, checks, files, contents
      @writes, @releases = [], []
    end
    def api(path, method: 'GET', body: nil)
      return @pr if path == 'pulls/9' && method == 'GET'
      if path == 'pulls/9/merge' && method == 'PUT'
        @writes << body
        return { 'merged' => true, 'sha' => MERGE }
      end
      raise "Unexpected request #{method} #{path}"
    end
    def pages(path)
      path.end_with?('/commits') ? @commits : @files
    end
    def checks(_number); @checks; end
    def content(path, sha, optional: false); @contents.fetch([path, sha]); end
    def release_security_fix(*arguments); @releases << arguments; end
  end

  def client(changes, current_checks: checks)
    contents = changes.to_h { |name, (before, after)| [[name, BASE], before] }.merge(changes.to_h { |name, (_, after)| [[name, HEAD], after] })
    FakeClient.new(pr: pr, commits: commits, checks: current_checks,
      files: changes.keys.map { |name| { 'filename' => name, 'status' => 'modified' } }, contents: contents, lookup: lookup)
  end

  def test_application_security_fix_merges_exact_head_then_requests_release
    fake = client({ 'Package.resolved' => [lock('1.0.0', BASE), lock('1.0.1', HEAD)] })
    fake.process(9, HEAD)
    assert_equal HEAD, fake.writes.first[:sha]
    assert_equal [[9, MERGE, ['GHSA-SYNTHETIC-TEST']]], fake.releases
  end

  def test_ci_fix_never_requests_an_app_release
    fake = client({ '.github/workflows/check.yml' => [workflow('1.0.0', BASE), workflow('1.0.1')] })
    fake.process(9, HEAD)
    assert_equal 1, fake.writes.length
    assert_empty fake.releases
  end

  def test_failed_check_prevents_merge_and_release
    fake = client({ 'Package.resolved' => [lock('1.0.0', BASE), lock('1.0.1', HEAD)] }, current_checks: checks + [{ 'name' => 'extra', 'bucket' => 'fail' }])
    fake.process(9, HEAD)
    assert_empty fake.writes
    assert_empty fake.releases
  end

  def test_dry_run_of_a_qualifying_security_fix_performs_no_writes
    changes = { 'Package.resolved' => [lock('1.0.0', BASE), lock('1.0.1', HEAD)] }
    contents = { ['Package.resolved', BASE] => changes.values.first.first, ['Package.resolved', HEAD] => changes.values.first.last }
    fake = FakeClient.new(pr: pr, commits: commits, checks: checks, files: [{ 'filename' => 'Package.resolved', 'status' => 'modified' }],
      contents: contents, lookup: lookup, dry_run: true)
    fake.process(9, HEAD)
    assert_empty fake.writes
    assert_empty fake.releases
  end

  class FakeReleaseClient < Policy::Client
    attr_reader :writes
    def initialize(already_released: false)
      super()
      @writes = []; @already_released = already_released
    end
    def api(path, method: 'GET', body: nil)
      if method == 'POST'
        @writes << [path, body]
        return { 'sha' => HEAD }
      end
      return { 'status' => 'ahead' } if path.start_with?('compare/')
      return [{ 'ref' => 'refs/tags/v1.4.0', 'object' => { 'type' => 'commit', 'sha' => @already_released ? MERGE : BASE } }] if path == 'git/matching-refs/tags/v'
      raise "Unexpected #{path}"
    end
    def pages(_path); [{ 'tag_name' => 'v1.4.0', 'draft' => false }]; end
  end

  def test_patch_tag_points_to_merge_and_explicitly_dispatches_ci
    fake = FakeReleaseClient.new
    fake.release_security_fix(9, MERGE, ['GHSA-SYNTHETIC-TEST'])
    assert_equal MERGE, fake.writes[0][1][:object]
    assert_equal 'refs/tags/v1.4.1', fake.writes[1][1][:ref]
    assert_equal ['actions/workflows/validate-and-release.yml/dispatches', { ref: 'v1.4.1', inputs: { security_pr: '9' } }], fake.writes[2]
  end

  def test_retry_does_not_duplicate_a_published_release
    fake = FakeReleaseClient.new(already_released: true)
    fake.release_security_fix(9, MERGE, ['GHSA-SYNTHETIC-TEST'])
    assert_empty fake.writes
  end
end
