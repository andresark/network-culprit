#!/usr/bin/env ruby
# Maintenance tooling only; the macOS app has no Ruby dependency.
require 'json'
require 'net/http'
require 'uri'

module DependencyVulnerabilityAudit
  def self.swift_queries(manifest, lock)
    dependencies = manifest.fetch('dependencies')
    raise 'Invalid manifest dependencies' unless dependencies.is_a?(Array)
    dependencies.each do |dependency|
      raise 'Only remote source-control Swift packages are audited' unless dependency.keys == ['sourceControl']
    end
    if manifest.fetch('targets').any? { |target| target['type'] == 'binary' }
      raise 'Binary targets need an explicit vulnerability audit design'
    end
    raise 'Commit Package.resolved for declared Swift dependencies' if !dependencies.empty? && lock.nil?
    return [] if lock.nil?
    pins = case lock.fetch('version')
           when 1 then lock.fetch('object').fetch('pins')
           when 2, 3 then lock.fetch('pins')
           else raise 'Unsupported Package.resolved format'
           end
    raise 'Declared dependencies have no resolved pins' if !dependencies.empty? && pins.empty?
    pins.flat_map do |pin|
      kind = pin['kind']
      raise 'Only remote source-control pins are audited' if kind && kind != 'remoteSourceControl'
      location = pin['location'] || pin.fetch('repositoryURL')
      uri = URI(location)
      raise 'Package locations must be public HTTPS URLs without credentials' unless uri.scheme == 'https' && uri.host && !uri.userinfo && !uri.query && !uri.fragment
      revision = pin.fetch('state').fetch('revision')
      raise 'Every package must have a full Git revision' unless revision.match?(/\A[0-9a-f]{40}\z/)
      queries = [{ 'commit' => revision }]
      version = pin['state']['version']
      if version
        name = location.sub(/\.git\z/, '').sub(%r{/$}, '')
        # GitHub paths are case-insensitive; OSV SwiftURL names use lowercase URLs.
        name = name.downcase if uri.host.downcase == 'github.com'
        queries << { 'package' => { 'ecosystem' => 'SwiftURL', 'name' => name }, 'version' => version }
      end
      queries
    end
  end

  def self.action_queries(contents)
    contents.flat_map do |content|
      content.lines.map do |line|
        next unless line.match?(/^\s*(?:-\s*)?uses:/)
        match = line.match(/^\s*(?:-\s*)?uses:\s*([\w.-]+\/[\w.\/-]+)@([0-9a-f]{40})\s+#\s+v(\d+\.\d+\.\d+)\s*$/)
        raise 'Every action must use a full SHA and exact release comment (# vX.Y.Z)' unless match
        name = match[1].split('/').first(2).join('/')
        [{ 'commit' => match[2] }, { 'package' => { 'ecosystem' => 'GitHub Actions', 'name' => name }, 'version' => match[3] }]
      end.compact.flatten(1)
    end.uniq
  end

  def self.post_osv(queries)
    uri = URI('https://api.osv.dev/v1/querybatch')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate('queries' => queries)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 40) { |http| http.request(request) }
    raise "OSV request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end

  def self.findings(queries, request: method(:post_osv))
    remaining = queries.uniq
    found = []
    pages = 0
    until remaining.empty?
      pages += 1
      raise 'OSV pagination exceeded safety limit' if pages > 100
      response = request.call(remaining)
      results = response.fetch('results')
      raise 'OSV response has wrong result count' unless results.is_a?(Array) && results.length == remaining.length
      next_queries = []
      results.each_with_index do |result, index|
        raise "OSV query error: #{result['error']}" if result.key?('error')
        result.fetch('vulns', []).each { |vulnerability| found << vulnerability.fetch('id') }
        token = result['next_page_token']
        next_queries << remaining[index].merge('page_token' => token) if token && !token.empty?
      end
      remaining = next_queries
    end
    found.uniq.sort
  end

  def self.run(root)
    manifest = JSON.parse(File.read(File.join(root, '.build/package-manifest.json')))
    lock_path = File.join(root, 'Package.resolved')
    lock = File.exist?(lock_path) ? JSON.parse(File.read(lock_path)) : nil
    swift = swift_queries(manifest, lock)
    workflows = Dir.glob(File.join(root, '.github/workflows/*.{yml,yaml}'))
    raise 'No workflows found to audit' if workflows.empty?
    actions = action_queries(workflows.map { |path| File.read(path) })
    raise 'No action pins found to audit' if actions.empty?
    queries = (swift + actions).uniq
    ids = findings(queries)
    puts "Swift package queries: #{swift.length}; workflow queries: #{actions.length}."
    unless ids.empty?
      warn "Known dependency advisories: #{ids.join(', ')}"
      ids.each { |id| warn "https://osv.dev/vulnerability/#{id}" }
      return 1
    end
    puts 'No matching known OSV advisories. Apple system components and optional external apps are outside this audit.'
    0
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit DependencyVulnerabilityAudit.run(File.expand_path('..', __dir__))
  rescue StandardError => error
    warn "Dependency audit failed: #{error.message}"
    exit 1
  end
end
