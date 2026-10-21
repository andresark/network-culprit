#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'base64'
require 'time'
require_relative 'audit-dependency-vulnerabilities'

module AutomaticSecurityMaintenance
  REPOSITORY = 'andresark/network-culprit'
  REQUIRED_CHECKS = ['Native macOS tests and dependency audit', 'Workflow security analysis'].freeze

  def self.eligible_identity?(pr, commits, expected_sha)
    pr.dig('user', 'login') == 'dependabot[bot]' && pr.dig('user', 'type') == 'Bot' &&
      !pr['draft'] && pr.dig('base', 'ref') == 'main' &&
      pr.dig('base', 'repo', 'full_name') == REPOSITORY && pr.dig('head', 'repo', 'full_name') == REPOSITORY &&
      pr.dig('head', 'sha') == expected_sha && !commits.empty? &&
      commits.all? { |commit| commit.dig('author', 'login') == 'dependabot[bot]' && commit.dig('commit', 'verification', 'verified') == true }
  end

  def self.all_checks_pass?(checks)
    REQUIRED_CHECKS.all? { |name| checks.any? { |check| check['name'] == name && check['bucket'] == 'pass' } } &&
      checks.all? { |check| ['pass', 'skipping'].include?(check['bucket']) }
  end

  def self.allowed_files?(files)
    !files.empty? && files.length <= 50 && files.all? do |file|
      ['Package.swift', 'Package.resolved'].include?(file['filename']) ||
        (file['status'] == 'modified' && file['filename'].match?(%r{\A\.github/workflows/[\w-]+\.ya?ml\z}))
    end
  end

  def self.without_action_references(value)
    case value
    when Hash then value.map { |key, child| [key, key == 'uses' ? '<action reference>' : without_action_references(child)] }.to_h
    when Array then value.map { |child| without_action_references(child) }
    else value
    end
  end

  def self.classify(changes, lookup: DependencyVulnerabilityAudit.method(:findings))
    before_queries = []; after_queries = []
    app_changed = changes.keys.any? { |path| ['Package.swift', 'Package.resolved'].include?(path) }
    changes.each do |path, pair|
      before, after = pair
      if path.start_with?('.github/workflows/')
        raise 'Workflow changes extend beyond action references' unless
          without_action_references(YAML.safe_load(before)) == without_action_references(YAML.safe_load(after))
        before_queries.concat(DependencyVulnerabilityAudit.action_queries([before]))
        after_queries.concat(DependencyVulnerabilityAudit.action_queries([after]))
      elsif path == 'Package.resolved'
        manifest = { 'dependencies' => [], 'targets' => [] }
        before_queries.concat(DependencyVulnerabilityAudit.swift_queries(manifest, before && JSON.parse(before)))
        after_queries.concat(DependencyVulnerabilityAudit.swift_queries(manifest, after && JSON.parse(after)))
      end
    end
    previous = before_queries.empty? ? [] : lookup.call(before_queries.uniq)
    current = after_queries.empty? ? [] : lookup.call(after_queries.uniq)
    raise 'The updated dependencies still have known advisories' unless current.empty?
    { 'security_fix' => !previous.empty?, 'app_changed' => app_changed, 'advisories' => previous }
  end

  class Client
    def initialize(lookup: DependencyVulnerabilityAudit.method(:findings), dry_run: false)
      @lookup = lookup
      @dry_run = dry_run
    end

    def command(*arguments, stdin: '', allow_pending: false)
      output, error, status = Open3.capture3('gh', *arguments, stdin_data: stdin)
      raise "GitHub request failed: #{error.strip}" unless status.success? || (allow_pending && status.exitstatus == 8)
      output
    end

    def api(path, method: 'GET', body: nil)
      arguments = ['api', '-X', method, "repos/#{REPOSITORY}/#{path}"]
      arguments += ['--input', '-'] if body
      result = command(*arguments, stdin: body ? JSON.generate(body) : '')
      result.strip.empty? ? nil : JSON.parse(result)
    end

    def pages(path)
      all = []
      (1..20).each do |page|
        values = api("#{path}#{path.include?('?') ? '&' : '?'}per_page=100&page=#{page}")
        all.concat(values)
        return all if values.length < 100
      end
      raise 'GitHub pagination safety limit exceeded'
    end

    def content(path, sha, optional: false)
      result = api("contents/#{path}?ref=#{sha}")
      raise 'Expected a bounded text dependency file' unless result['type'] == 'file' && result['encoding'] == 'base64' && result['size'] < 1_000_000
      Base64.decode64(result.fetch('content')).force_encoding(Encoding::UTF_8)
    rescue RuntimeError => error
      return nil if optional && error.message.include?('HTTP 404')
      raise
    end

    def checks(number)
      JSON.parse(command('pr', 'checks', number.to_s, '--repo', REPOSITORY, '--json', 'name,bucket', allow_pending: true))
    end

    def tag_commit(reference)
      object = reference.fetch('object')
      4.times do
        return object['sha'] if object['type'] == 'commit'
        raise 'Unexpected release tag type' unless object['type'] == 'tag'
        object = api("git/tags/#{object.fetch('sha')}").fetch('object')
      end
      raise 'Nested release tag limit exceeded'
    end

    def release_security_fix(number, merge_sha, advisories)
      comparison = api("compare/#{merge_sha}...main")
      raise 'Security merge is not on main' unless ['ahead', 'identical'].include?(comparison['status'])
      references = api('git/matching-refs/tags/v')
      releases = pages('releases')
      existing = references.find { |reference| tag_commit(reference) == merge_sha }
      if existing
        tag = existing.fetch('ref').delete_prefix('refs/tags/')
        if releases.any? { |release| release['tag_name'] == tag && !release['draft'] }
          puts "Security fix ##{number} is already released as #{tag}."
          return
        end
      else
        versions = (references.map { |reference| reference['ref'].delete_prefix('refs/tags/') } + releases.map { |release| release['tag_name'] }).map do |value|
          match = value.match(/\Av(\d+)\.(\d+)\.(\d+)\z/)
          match && match.captures.map(&:to_i)
        end.compact
        raise 'No semantic release baseline exists' if versions.empty?
        major, minor, patch = versions.max
        tag = "v#{major}.#{minor}.#{patch + 1}"
        object = api('git/tags', method: 'POST', body: {
          tag: tag, object: merge_sha, type: 'commit',
          message: "Automatic security release for Dependabot PR ##{number}\n#{advisories.join(', ')}",
          tagger: { name: 'Network Culprit Automatic Security Maintenance', email: '41898282+github-actions[bot]@users.noreply.github.com', date: Time.now.utc.iso8601 }
        })
        api('git/refs', method: 'POST', body: { ref: "refs/tags/#{tag}", sha: object.fetch('sha') })
      end
      # GITHUB_TOKEN tag pushes do not start push workflows. Explicit dispatch
      # is supported, needs no stored PAT, and reruns all release gates.
      api('actions/workflows/validate-and-release.yml/dispatches', method: 'POST', body: { ref: tag, inputs: { security_pr: number.to_s } })
      puts "Dispatched verified app security release #{tag} for PR ##{number}."
    end

    def process(number, expected_sha)
      raise 'Invalid PR number or commit SHA' unless number.to_s.match?(/\A[1-9]\d*\z/) && expected_sha.match?(/\A[0-9a-f]{40}\z/)
      pr = api("pulls/#{number}")
      commits = pages("pulls/#{number}/commits")
      unless AutomaticSecurityMaintenance.eligible_identity?(pr, commits, expected_sha)
        puts "PR ##{number}: not an eligible, verified Dependabot head. No changes."
        return
      end
      current_checks = checks(number)
      12.times do
        break unless current_checks.any? { |check| check['bucket'] == 'pending' }
        sleep 5
        current_checks = checks(number)
      end
      unless AutomaticSecurityMaintenance.all_checks_pass?(current_checks)
        puts "PR ##{number}: waiting for all checks. No changes."
        return
      end
      if pr['state'] != 'open' && !pr['merged']
        puts "PR ##{number}: closed without merging. No changes."
        return
      end
      files = pages("pulls/#{number}/files")
      unless AutomaticSecurityMaintenance.allowed_files?(files)
        puts "PR ##{number}: changes exceed the dependency-only allowlist. No changes."
        return
      end
      before_sha = pr['merged'] ? api("git/commits/#{pr.fetch('merge_commit_sha')}").fetch('parents').first.fetch('sha') : pr.dig('base', 'sha')
      changes = files.to_h do |file|
        path = file.fetch('filename')
        [path, [content(path, before_sha, optional: file['status'] == 'added'), content(path, expected_sha, optional: file['status'] == 'removed')]]
      end
      classification = AutomaticSecurityMaintenance.classify(changes, lookup: @lookup)
      unless classification['security_fix']
        puts "PR ##{number}: routine version update; no fixed known advisory was established. No changes."
        return
      end
      if @dry_run
        puts "DRY RUN: PR ##{number} qualifies; app release needed: #{classification['app_changed']}. No changes."
        return
      end
      if pr['merged']
        merge_sha = pr.fetch('merge_commit_sha')
      else
        result = api("pulls/#{number}/merge", method: 'PUT', body: { sha: expected_sha, merge_method: 'squash',
          commit_title: "Fix dependency security advisories (##{number})", commit_message: classification['advisories'].join(', ') })
        raise 'GitHub did not merge the checked head' unless result['merged']
        merge_sha = result.fetch('sha')
        puts "Merged Dependabot security PR ##{number}: #{classification['advisories'].join(', ')}"
      end
      if classification['app_changed']
        release_security_fix(number, merge_sha, classification['advisories'])
      else
        puts "PR ##{number}: CI-only security fix; an app release is unnecessary."
      end
    end

    def run(event)
      if !event['workflow_run'] && !event['inputs']
        # Reconcile open bot PRs after transient API errors, late checks, or
        # delayed advisory ingestion. A successful exact-head validation is
        # still mandatory; the schedule never authorizes unchecked heads.
        pages('pulls?state=open&base=main').each do |pr|
          next unless pr.dig('user', 'login') == 'dependabot[bot]'
          sha = pr.dig('head', 'sha')
          raise 'Invalid scheduled PR head' unless sha.to_s.match?(/\A[0-9a-f]{40}\z/)
          runs = api("actions/workflows/validate-and-release.yml/runs?event=pull_request&head_sha=#{sha}&status=success&per_page=100").fetch('workflow_runs')
          next unless runs.any? { |run| run['head_sha'] == sha && run['conclusion'] == 'success' && run['path'] == '.github/workflows/validate-and-release.yml' }
          process(pr.fetch('number'), sha)
        end
        return
      end
      workflow = if event['workflow_run']
                   event.fetch('workflow_run')
                 else
                   id = event.fetch('inputs').fetch('validation_run_id')
                   raise 'Invalid validation run ID' unless id.match?(/\A[1-9]\d*\z/)
                   @dry_run = true
                   api("actions/runs/#{id}")
                 end
      raise 'Unexpected validation workflow' unless workflow['path'] == '.github/workflows/validate-and-release.yml' && workflow['conclusion'] == 'success'
      return puts('Only successful pull-request validation can authorize a merge.') unless workflow['event'] == 'pull_request'
      sha = workflow.fetch('head_sha')
      raise 'Unexpected repository' unless workflow.dig('repository', 'full_name') == REPOSITORY
      pull_requests = workflow.fetch('pull_requests')
      pull_requests = api("commits/#{sha}/pulls") if pull_requests.empty?
      pull_requests.each { |pr| process(pr.fetch('number'), sha) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise 'Unexpected repository' unless ENV.fetch('GITHUB_REPOSITORY') == AutomaticSecurityMaintenance::REPOSITORY
    AutomaticSecurityMaintenance::Client.new.run(JSON.parse(File.read(ENV.fetch('GITHUB_EVENT_PATH'))))
  rescue StandardError => error
    warn "Automatic security maintenance stopped: #{error.message}"
    exit 1
  end
end
