#!/usr/bin/env ruby
#
require 'date'
require 'deep_merge'
require 'fileutils'
require 'gitlab'
require 'json'
require 'net/http'
require 'optparse'
require 'parallel'
require 'r10k/git'
require 'set'
require 'simp/componentinfo'
require 'yaml'

# Temporary monkey patch to extract RPM name and arch
# FIXME Move appropriately into Simp::ComponentInfo::load_xxx_info()
#       methods in simp-rake-helpers
module Simp
  class ComponentInfo
    def rpm_name
      return @rpm_name if @rpm_name

      if @type == :module
        require 'json'
        metadata_file = File.join(@component_dir, 'metadata.json')
        metadata = JSON.parse(File.read(metadata_file))
        @rpm_name = "pupmod-#{metadata['name']}"
      else
        # Some assets us LUA in their spec files to read a top-level CHANGELOG.
        # So, have to be in the component directory for the RPM query to work
        # and use a relative path for the spec file.
        Dir.chdir(@component_dir) do
          rpm_spec_file = Dir.glob(File.join('build', '*.spec')).first

          # Determine asset RPM name, which we will ASSUME to be the main
          # package version.  The RPM query, below, will return the main
          # package followed by subpackages.
          name_query = "rpm -q --queryformat '%{NAME}\\n' --specfile #{rpm_spec_file}"
          rpm_name_list = `#{name_query} 2> /dev/null`
          if $?.exitstatus != 0
            msg = "Could not extract name from #{rpm_spec_file}. To debug, execute:\n" +
              "   #{name_query}"
            $stderr.puts("WARN: #{msg}")
          else
            @rpm_name = rpm_name_list.split("\n")[0].strip
          end
        end
      end
    end

    def arch
      return @arch if @arch

      if @type == :module
        @arch = 'noarch'
      else
        rpm_spec_file = Dir.glob(File.join(@component_dir, 'build', '*.spec')).first

        # Determine asset arch, which we will ASSUME to be the main
        # package version.  The RPM query, below, will return the main
        # package followed by subpackages.
        arch_query = "rpm -q --queryformat '%{ARCH}\\n' --specfile #{rpm_spec_file}"
        rpm_arch_list = `#{arch_query} 2> /dev/null`
        if $?.exitstatus != 0
          msg = "Could not extract arch from #{rpm_spec_file}. To debug, execute:\n" + 
            "   #{arch_query}"
        else
          @arch = rpm_arch_list.split("\n")[0].strip
        end
      end
      @arch
    end
  end
end

# parts lifted from simp-rake-helpers R10KHelper
class R10K::Git::ShellGit::ThinRepository
  def cache_repo
    @cache_repo
  end
end

class PuppetfileHelper
  attr_accessor :puppetfile
  attr_accessor :modules
  attr_accessor :basedir

  require 'r10k/puppetfile'

  def initialize(puppetfile, root_dir, purge_cache = true)
    @modules = []
    @gitlab_client = nil

    Dir.chdir(root_dir) do
      cache_dir = File.join(root_dir,'.r10k_cache')
      FileUtils.rm_rf(cache_dir) if purge_cache
      FileUtils.mkdir_p(cache_dir)
      R10K::Git::Cache.settings[:cache_root] = cache_dir

      r10k = R10K::Puppetfile.new(Dir.pwd, nil, puppetfile)
      r10k.load!

      @modules = r10k.modules.collect do |mod|
        mod = {
          :name        => mod.name,
          :path        => mod.path.to_s,
#          :remote      => mod.repo.instance_variable_get('@remote'),
          :desired_ref => mod.desired_ref,
#TODO Can we use these instead of querying git for the info?
#          :git_source  => mod.repo.repo.origin,
#          :git_ref     => mod.repo.head,
          :r10k_module => mod,
          :r10k_cache  => mod.repo.repo.cache_repo
        }
      end
    end
  end
end



class SimpReleaseStatusGenerator

  class InvalidModule < StandardError; end
  GITHUB_URL_BASE = 'https://github.com/simp/'
  FORGE_URL_BASE  = 'https://forgeapi.puppet.com/v3/releases/'
  PCLOUD_URL_BASE = 'https://packagecloud.io/simp-project/6_X/packages/el/'
  GITLAB_API_URL  = 'https://gitlab.com/api/v4'
  GITLAB_ORG      = 'simp'

  def initialize

    @options = {
      :puppetfile              => nil,
      :last_release_puppetfile => nil,
      :root_dir                => File.expand_path('.'),
      :output_file             => 'simp_component_release_status.csv',
      :clean_start             => true,
      :release_status          => true,
      :test_status             => true,
      :verbose                 => false,
      :help_requested          => false
    }
    @last_release_mods = nil
    @github_api_limit_reached = false
  end

  def check_out_projects
    debug("Preparing a clean projects checkout at #{@options[:root_dir]}")
    #FIXME the root directory for checkouts should be pulled from the Puppetfile
    FileUtils.rm_rf(File.join(@options[:root_dir], 'src'))

    helper = PuppetfileHelper.new(@options[:puppetfile], @options[:root_dir])
    Parallel.map( Array(helper.modules), :progress => 'Submodule Checkout') do |mod|
      Dir.chdir(@options[:root_dir]) do
        FileUtils.mkdir_p(mod[:path])

        # make sure R10K cache is current, as that is what populates R10K 'thin' git repos
        # used in the module sync operation
#TODO do I need to do this?
        unless mod[:r10k_cache].synced?
          mod[:r10k_cache].sync
        end

        # checkout the module at the revision specified in the Puppetfile
        mod[:r10k_module].sync
      end
    end
  end

  # @return whether actual jobs run pass validator
  #
  # Validates
  # * when validation stage is configured, at least one unit test job was run
  #   - Only detects unit test jobs containing 'unit' or 'test' in their name.
  #   - FIXME Does not work for projects with other tests that do not conform
  #     to this convention:
  #     - simp-gpgkeys
  #     - simp-rsync-skeleton
  #     - simp-selinux_policy
  # * when acceptance stage is configured, at least 1 acceptance job was run
  # * when compliance stage is configured, at least 1 compliance job was run
  #
  def compare_gitlab_results(expected_jobs, passed_jobs, failed_jobs)
    all_jobs = passed_jobs.deep_merge(failed_jobs)
    debug("All possible jobs=#{expected_jobs.to_yaml}")
    debug("Actual jobs=#{all_jobs.to_yaml}")

    return false unless expected_jobs.keys.sort == all_jobs.keys.sort

    valid = true
    if expected_jobs.key?('validation')
      exp_jobs = expected_jobs['validation'].sort
      act_jobs = all_jobs['validation'].sort
      if act_jobs.empty?
        valid = false
      elsif (act_jobs - exp_jobs).empty?
        # make sure subset includes unit tests
        valid = false if act_jobs.grep(/unit|test/).empty?
      else
        # Shouldn't get here, but this means there are jobs that were run
        # that were not in the .gitlab-ci.yml <==> Different git ref.
        valid = false
      end
    end

    if expected_jobs.key?('acceptance')
      exp_jobs = expected_jobs['acceptance'].sort
      act_jobs = all_jobs['acceptance'].sort
      if act_jobs.empty?
        valid = false
      elsif !(act_jobs - exp_jobs).empty?
        # Shouldn't get here, but this means there are jobs that were run
        # that were not in the .gitlab-ci.yml <==> Different git ref.
        valid = false
      end
    end

    if expected_jobs.key?('compliance')
      exp_jobs = expected_jobs['compliance'].sort
      act_jobs = all_jobs['compliance'].sort
      if act_jobs.empty?
        valid = false
      elsif !(act_jobs - exp_jobs).empty?
        # Shouldn't get here, but this means there are jobs that were run
        # that were not in the .gitlab-ci.yml <==> Different git ref.
        valid = false
      end
    end

    valid
  end

  def format_job_results(jobs_hash)
    jobs = []
    jobs_hash.each_key do |stage|
      jobs << "#{stage}:#{ jobs_hash[stage].join(' ')}"
    end

    jobs.join(' ; ')
  end

=begin
  def execute(command, log_command=true)
    info("Executing: #{command}") if log_command
    result = nil
    unless @options[:dry_run]
      result = `#{command} 2>&1 | egrep -v 'warning: already initialized constant|warning: previous definition|internal vendored libraries are Private APIs and can change without warning'`
    end
    result
  end
=end
  # returns Array of stages for which results are expected
  def get_configured_gitlab_jobs(gitlab_config_file)
    config= YAML.load(File.read(gitlab_config_file))
    jobs = {}
    config.each { |key,value|
      if value.is_a?(Hash) && value.key?('stage')
        if (key != '.unit_tests') && (key != '.lint_tests') && (value['stage'] == 'validation')
          jobs['validation'] = [] unless jobs.key?('validation')
          jobs['validation'] << key
        elsif (key != '.acceptance_base') && (value['stage'] == 'acceptance')
          jobs['acceptance'] = [] unless jobs.key?('acceptance')
          jobs['acceptance'] << key
        elsif (key != '.compliance_base') && (value['stage'] == 'compliance')
          jobs['compliance'] = [] unless jobs.key?('compliance')
          jobs['compliance'] << key
        end
      end
    }

    jobs
  end

  # returns the latest commit ref
  def get_gitlab_ref(git_url)
    return 'TBD' if ENV['GITLAB_ACCESS_TOKEN'].nil?
    proj_name = File.basename(git_url, '.git')

    gitlab_ref = nil
    begin
      proj = gitlab_client.project("#{GITLAB_ORG}/#{proj_name}")
      commits = gitlab_client.repo_commits(proj.id, page: 1)
      if commits
        gitlab_ref = commits[0].to_hash['id']
      end
    rescue =>e
      # can happen if a GitLab project for the component does not exist
      msg = "Unable to get GitLab ref for #{proj_name}:\n  #{e.message}"
      warning(msg)
    end
    gitlab_ref
  end

  def get_gitlab_pipeline_jobs(pipeline_jobs)
    passed_jobs_per_stage = {}
    failed_jobs_per_stage = {}
    pipeline_jobs.each do |job|
      if job.status == 'failed'
        unless failed_jobs_per_stage.key?(job.stage)
          failed_jobs_per_stage[job.stage] = []
        end
        failed_jobs_per_stage[job.stage] << job.name
      else
        unless passed_jobs_per_stage.key?(job.stage)
          passed_jobs_per_stage[job.stage] = []
        end
        passed_jobs_per_stage[job.stage] << job.name
      end
    end

    [ passed_jobs_per_stage, failed_jobs_per_stage ]
  end

  def get_gitlab_pipeline_failed_jobs(pipeline_jobs)
    failed_jobs_per_stage = {}
    pipeline_jobs.each do |job|
      if job.status == 'failed'
        unless failed_jobs_per_stage.key?(job.stage)
          failed_jobs_per_stage[job.stage] = []
        end
        failed_jobs_per_stage[job.stage] << job.name
      end
    end

    stage_failures = []
    failed_jobs_per_stage.each_key do |stage|
      stage_failures << "#{stage}:#{failed_jobs_per_stage[stage].join(' ')}"
    end
    stage_failures.join(' ; ')
  end

  def get_gitlab_test_status(git_url, git_ref, expected_jobs)
    return 'TBD' if ENV['GITLAB_ACCESS_TOKEN'].nil?
    proj_name = File.basename(git_url, '.git')

    status = 'none'
    passed_jobs = ''
    failed_jobs = ''
    begin
      proj = gitlab_client.project("#{GITLAB_ORG}/#{proj_name}")

      # Retrieve the pipelines for the git ref on the master branch sorted by
      # the number of jobs in the pipeline.
      pipelines = gitlab_client.pipelines(proj.id).select { |p|
        (p.ref == 'master') &&
        (p.sha == git_ref) &&
        ((p.status == 'success') || (p.status == 'failed'))
      }.sort_by{ |p| gitlab_client.pipeline_jobs(proj.id, p.id).size }

      pipeline = nil
      unless pipelines.empty?
        # Find the latest job with the maximum number of jobs. Need to do this
        # to cull scheduled pipelines that run very few jobs.
        max_jobs = gitlab_client.pipeline_jobs(proj.id, pipelines.last.id).size
        pipelines.delete_if { |p| gitlab_client.pipeline_jobs(proj.id, p.id).size != max_jobs }
        pipeline = pipelines.max_by{ |p| p.updated_at }
      end

      if pipeline
        debug(">>>> Retrieving #{proj.name} pipeline jobs for #{proj_name}")
        jobs = gitlab_client.pipeline_jobs(proj.id, pipeline.id)
        create_time = jobs.map { |job| job.created_at }.sort.first
        passed_jobs_hash, failed_jobs_hash = get_gitlab_pipeline_jobs(jobs)
        prefix = ''
        unless compare_gitlab_results(expected_jobs, passed_jobs_hash, failed_jobs_hash)
          prefix = 'INCOMPLETE '
        end
        status = "#{prefix}#{pipeline.status.upcase} #{create_time} #{pipeline.web_url}"
        passed_jobs = format_job_results(passed_jobs_hash)
        failed_jobs = format_job_results(failed_jobs_hash)
      end
    rescue =>e
      # can happen if a GitLab project for the component does not exist
      msg = "Unable to get GitLab test status for #{proj_name}:\n  #{e.message}"
      warning(msg)
    end
    [ status, passed_jobs, failed_jobs ]
  end

  def get_git_info
    git_ref = `git log -n 1 --format=%H`.strip
    git_origin_line = `git remote -v`.split("\n").delete_if do |line|
      line.match(/^origin/).nil? or line.match(/\(fetch\)/).nil?
    end
    git_origin = git_origin_line[0].gsub(/^origin/,'').gsub(/.fetch.$/,'').strip
    [git_origin, git_ref]
  end

  def get_changelog_url(proj_info, git_origin)
    if proj_info.type == :module
      changelog_url = "#{git_origin}/blob/master/CHANGELOG"
    else
      spec_files = Dir.glob(File.join(proj_info.component_dir, 'build', '*.spec'))
      if spec_files.empty?
         changelog_url = 'UNKNOWN'
      else
        changelog_url = "#{git_origin}/blob/master/build/#{File.basename(spec_files[0])}"
      end
    end
    changelog_url
  end

  def url_exists?(url)
    uri = URI.parse(url)
    query = Net::HTTP.new(uri.host, uri.port)
    query.use_ssl = true
    result = query.request_head(uri.path)
    debug("Checking for #{url}:\n#{result}")
    (result.code == '200')
  end

  def get_forge_status(proj_info)
    if proj_info.type == :module
      url = FORGE_URL_BASE + "simp-#{File.basename(proj_info.component_dir)}-#{proj_info.version}"
      uri = URI(url)
      result = JSON.parse(Net::HTTP.get(uri))
      if result.key?('updated_at')
        timestamp = result['updated_at']
        # using local time isn't kosher but helps maintainers who are largely
        # in the same timezone
        forge_published = DateTime.parse(timestamp).to_time.localtime.to_date.to_s
      elsif result.key?('created_at')
        timestamp = result['created_at']
        forge_published = DateTime.parse(timestamp).to_time.localtime.to_date.to_s
      else
        forge_published = :unreleased
      end
    else
      forge_published = :not_applicable
    end
    forge_published
  end

  def get_project_list
    projects = get_assets
    projects << get_simp_owned_modules
    projects.flatten
  end

  def get_release_status(proj_info, git_origin)
    tag_found = false
    Dir.chdir(proj_info.component_dir) do
    # determine if latest version is tagged
      `git fetch -t origin 2>/dev/null`
      tags = `git tag -l`.split("\n")
      debug("Available tags from origin = #{tags}")
      tag_found = tags.include?(proj_info.version)
    end
    if (tag_found)
      if @github_api_limit_reached
        # No point trying to curl results...
        :tagged_unknown_release_status
      else
        project_name = git_origin.split('/').last
        project_name.gsub!(/\.git$/,'')
        releases_url = "https://api.github.com/repos/simp/#{project_name}/releases/tags/#{proj_info.version}"

        cmd = [
          'curl',
          '-H "Accept: application/vnd.github.v3+json"',
          " -XGET #{releases_url}",
          '-s'
        ].join(' ')

        cmd += " -H \"Authorization: token #{ENV['GITHUB_ACCESS_TOKEN']}\"" if ENV['GITHUB_ACCESS_TOKEN']

        github_release_results = JSON.parse(`#{cmd}`)
        debug(github_release_results.to_s)
        if github_release_results.key?('tag_name')
          if github_release_results.key?('published_at')
            timestamp = github_release_results['published_at']
            # using local time isn't kosher but helps maintainers who are largely
            # in the same timezone
            DateTime.parse(timestamp).to_time.localtime.to_date.to_s
          else
            :released
          end
        else
          if github_release_results.key?('message') and github_release_results['message'].match(/Not Found/i)
            :tagged
          elsif github_release_results.key?('message') and github_release_results['message'].match(/Moved Permanently/i)
            # In one odd case (simp-rsync_data_pre64) we work around the
            # Puppetfile limitation that only allows one entry per git URL
            # by using an old name for the repo. Unfortunately, the GitHub API
            # doesn't follow redirects.
            # TODO Use the response to reformulate the request with the repo ID
            # instead.  See https://stackoverflow.com/questions/28863131/github-api-how-to-keep-track-of-moved-repos-projects
            :unknown_repo_moved
          else
            # we get here if the GitHub API interface has rate limited
            # queries (happens most often when an access token is NOT
            # used)
            @github_api_limit_reached = true
            :tagged_unknown_release_status
          end
        end
      end
    else
      :unreleased
    end
  end

  # FIXME Package cloud is no longer applicable.  Need to pull status from
  # new SIMP repos
  def get_rpm_status(proj_info)
    if proj_info.type == :module
      # FIXME This ASSUMES the release qualifier is 0 instead of using
      #       simp-core/build/rpm/dependencies.yaml.
      rpm = "#{proj_info.rpm_name}-#{proj_info.version}-0.#{proj_info.arch}.rpm"
      url_el6 = PCLOUD_URL_BASE + "6/" + rpm
      url_el7 = PCLOUD_URL_BASE + "7/" + rpm
    else
      # FIXME If the RPM release qualifier has a %dist macro in it, there
      # is no way to accurately extract it from the spec file. The logic
      # below is a hack!
      rpm = "#{proj_info.rpm_name}-#{proj_info.version}-#{proj_info.release}.#{proj_info.arch}.rpm"
      url_el6 = PCLOUD_URL_BASE + "6/" + rpm
      url_el6.gsub!('el7','el6')
      url_el7 = PCLOUD_URL_BASE + "7/" + rpm
      url_el7.gsub!('el6','el7')
    end

    # query PackageCloud to see if a release to both el6 and el7 repos has been made
    # Note that each URL is for a page with a download button, not the RPM itself.
    debug("Checking existence of #{url_el6}: #{url_exists?(url_el6) ? 'exists' : 'does not exist'}")
    debug("Checking existence of #{url_el7}: #{url_exists?(url_el7) ? 'exists' : 'does not exist'}")
    rpms_found = url_exists?(url_el6) && url_exists?(url_el7)
    rpms_found = url_exists?(url_el6) && url_exists?(url_el7)
    rpms_released = rpms_found ? :released : :unreleased
    rpms_released
  end

  def get_simp_owned_modules
    modules_dir = File.join(@options[:root_dir], 'src', 'puppet', 'modules')
    simp_modules = []

    return simp_modules unless Dir.exist?(modules_dir)
    # determine all SIMP-owned modules
    modules = Dir.entries(modules_dir).delete_if { |dir| dir[0] == '.' }
    modules.sort.each do |module_name|
      module_path = File.expand_path(File.join(modules_dir, module_name))
      begin
        metadata = load_module_metadata(module_path)
        if metadata['name'].split('-')[0] == 'simp'
          simp_modules << module_path
        end
      rescue InvalidModule => e
        warning("Skipping invalid module: #{module_name}: #{e}")
      end
    end

    simp_modules.sort
  end

  def get_assets
    assets_dir = File.join(@options[:root_dir], 'src', 'assets')
    return [] unless Dir.exist?(assets_dir)
    assets = Dir.entries(assets_dir).delete_if { |dir| dir[0] == '.' }
    assets.map! { |asset| File.expand_path(File.join(assets_dir, asset)) }
    assets.sort
  end

  def gitlab_client
    return @gitlab_client unless @gitlab_client.nil?

    @gitlab_client = Gitlab.client(
      :endpoint      => GITLAB_API_URL,
      :private_token => ENV['GITLAB_ACCESS_TOKEN']
    )
    @gitlab_client
  end

  def load_module_metadata( file_path = nil )
    require 'json'
    begin
      JSON.parse(File.read(File.join(file_path, 'metadata.json')))
    rescue => e
      raise InvalidModule.new(e.message)
    end
  end

  # Get the last versions of components from a SIMP release Puppetfile
  def get_last_versions
    @last_release_mods = {}
    helper = PuppetfileHelper.new(@options[:last_release_puppetfile], @options[:root_dir], false)
    helper.modules.each do |mod|
      @last_release_mods[mod[:name]] = mod[:desired_ref]
    end
  end

  def debug(msg)
    if @options[:verbose]
      puts(msg)
      log(msg)
    end
  end

  def info(msg)
    log(msg)
  end

  def warning(msg)
    message = msg.gsub(/WARNING./,'')
    $stderr.puts("WARNING: #{message}")
    log("WARNING: #{message}") if @options[:verbose]
  end

  def log(msg)
    unless @log_file
      @log_file = File.open(@options[:output_file], 'w')
    end
    @log_file.puts(msg) unless msg.nil?
    @log_file.flush
  end

  def parse_command_line(args)

   program = File.basename(__FILE__)
    opt_parser = OptionParser.new do |opts|
      opts.banner = [
        "Usage: GITHUB_ACCESS_TOKEN=USER_API_TOKEN #{program} [OPTIONS] -p PUPPETFILE",
        '         OR (release info incomplete due to GitHub rate limiting)',
        "       #{program} [OPTIONS] -p PUPPETFILE"
      ].join("\n")
      opts.separator ''

      opts.on(
        '-d', '--root-dir ROOT_DIR',
        'Root directory in which projects will be checked out.',
        'Defaults to current directory.'
      ) do |root_dir|
        @options[:root_dir] = File.expand_path(root_dir)
      end

      opts.on(
        '-o', '--outfile OUTFILE',
        "Output file. Defaults to #{@options[:output_file]}"
      ) do |output_file|
        @options[:output_file] = File.expand_path(output_file)
      end

      opts.on(
        '-p', '--puppetfile PUPPETFILE',
        'Puppetfile containing all components that may be in a SIMP release.',
      ) do |puppetfile|
        @options[:puppetfile] = File.expand_path(puppetfile)
      end

      opts.on(
        '-l', '--last-release-puppetfile PUPPETFILE',
        'Puppetfile of last SIMP release. When specified, the component',
        'versions in this file will be listed along with the latest',
        'component versions.'
      ) do |puppetfile|
        @options[:last_release_puppetfile] = File.expand_path(puppetfile)
      end


      opts.on(
        '-s', '--[no-]clean-start',
        'Start with a fresh checkout of components (Puppet modules',
        'and assets). Existing component directories will be removed.',
        "Defaults to #{@options[:clean_start]}."
      ) do |clean_start|
        @options[:clean_start] = clean_start
      end

      opts.on(
        '--no-release-status',
        'Do not verify module and RPM release/publication'
      ) do
        @options[:release_status] = false
      end

      opts.on(
        '--no-test-status',
        'Do not query GitLab for test status'
      ) do
        @options[:test_status] = false
      end

      opts.on(
        '-v', '--verbose',
        'Print all commands executed'
      ) do
        @options[:verbose] = true
      end

      opts.on( "-h", "--help", "Print this help message") do
        @options[:help_requested] = true
        puts opts
      end
    end


    begin
      opt_parser.parse!(args)

      unless @options[:help_requested]
        raise ('Puppetfile containing all components must be specified') if @options[:puppetfile].nil?
      end
    rescue RuntimeError,OptionParser::ParseError => e
      raise "#{e.message}\n#{opt_parser.to_s}"
    end
  ensure
    @log_file.close unless @log_file.nil?
  end

  def report_results(results)
    debug('-'*10)
    columns = [
      'Component',
      'Proposed Version',
      (@last_release_mods.nil?) ? nil : 'Version in Last SIMP',
      @options[:release_status] ? 'GitHub Released' : nil,
      @options[:release_status] ? 'Forge Released' : nil,
      'GitLab Current',
      @options[:test_status] ? 'GitLab Test Status' : nil,
      @options[:test_status] ? 'GitLab Passed Jobs' : nil,
      @options[:test_status] ? 'GitLab Failed Jobs' : nil,
# RPM release check needs to be fixed
#      @options[:release_status] ? 'RPM Released' : nil,
      'Changelog'
    ]
    info(columns.compact.join(','))
    results.each do |project, proj_info|
      project_data = [
        project,
        proj_info[:latest_version],
        (@last_release_mods.nil?) ? nil : proj_info[:version_last_simp_release],
        @options[:release_status] ? translate_status(proj_info[:github_released]) : nil,
        @options[:release_status] ? translate_status(proj_info[:forge_released]) : nil,
        proj_info[:gitlab_current],
        @options[:test_status] ? proj_info[:gitlab_test_status] : nil,
        @options[:test_status] ? proj_info[:gitlab_passed_jobs] : nil,
        @options[:test_status] ? proj_info[:gitlab_failed_jobs] : nil,
# RPM release check needs to be fixed
#        @options[:release_status].nil? nil : translate_status(proj_info[:rpm_released]),
        proj_info[:changelog_url],
      ]
      info(project_data.compact.join(','))
    end
  end

  def run(args)
    parse_command_line(args)
    return 0 if @options[:help_requested] # already have logged help

    if ENV['GITHUB_ACCESS_TOKEN'].nil? && @options[:release_status]
      msg = <<EOM
GITHUB_ACCESS_TOKEN environment variable not detected.

  GitHub queries may be rate limited, which will prevent
  this program from determining GitHub release status.
  Obtain an GitHub OAUTH token, set GITHUB_ACCESS_TOKEN
  to it, and re-run for best results.

EOM
      warning(msg)
    end

#FIXME GITLAB_ACCESS_TOKEN also used for git ref comparisons
    if ENV['GITLAB_ACCESS_TOKEN'].nil? & @options[:test_status]
      msg = <<EOM
GITLAB_ACCESS_TOKEN environment variable not detected.
No acceptance test results will be pulled from GitLab.
EOM
      warning(msg)
    end

    debug("Running with options = <#{args.join(' ')}>") unless args.empty?
    debug("Internal options=#{@options}")
    puts("START TIME: #{Time.now}")

    get_last_versions if @options[:last_release_puppetfile]
    check_out_projects if @options[:clean_start]

    results = {}
    get_project_list.each do |project_dir|
      project = File.basename(project_dir)
      debug('='*80)
      debug("Processing '#{project}'")
      begin
        proj_info = nil
        git_origin = nil
        git_ref = nil
        Dir.chdir(project_dir) do
          proj_info = Simp::ComponentInfo.new(project_dir, true, @options[:verbose])
          git_origin, git_ref = get_git_info
        end

        gitlab_ref = get_gitlab_ref(git_origin)

        unless gitlab_ref.nil?
          if git_ref != gitlab_ref
            msg = [
              "Git reference mismatch for '#{project}':",
              "  GitHub ref = #{git_ref}",
              "  GitLab ref = #{gitlab_ref}"
            ].join("\n")
            warning(msg)
          end
        end

        entry = {
          :latest_version     => proj_info.version,
          :gitlab_current     => gitlab_ref.nil? ? 'N/A' : (git_ref == gitlab_ref),
          :changelog_url      => get_changelog_url(proj_info, git_origin)
        }

        if @options[:test_status]
          gitlab_config_file = File.join(project_dir, '.gitlab-ci.yml')
          if File.exist?(gitlab_config_file)
            expected_jobs = get_configured_gitlab_jobs(gitlab_config_file)
            gitlab_test_status, gitlab_passed_jobs, gitlab_failed_jobs =
              get_gitlab_test_status(git_origin, git_ref, expected_jobs)

            entry[:gitlab_test_status] = gitlab_test_status
            entry[:gitlab_passed_jobs] = gitlab_passed_jobs
            entry[:gitlab_failed_jobs] = gitlab_failed_jobs
          else
            entry[:gitlab_test_status] = 'N/A'
            entry[:gitlab_passed_jobs] = ''
            entry[:gitlab_failed_jobs] = ''
          end
        end

        if @options[:release_status]
          entry[:github_released] = get_release_status(proj_info, git_origin)
          entry[:forge_released] = get_forge_status(proj_info)
# RPM release checke needs to be fixed
#          entry[:rpm_released] = get_rpm_status(proj_info)
        end

      rescue => e
        warning("#{project}: #{e}")
        debug(e.backtrace.join("\n"))
        entry = {
          :latest_version     => :unknown,
          :gitlab_current     => :unknown,
          :gitlab_test_status => :unknown,
          :gitlab_passed_jobs => :unknown,
          :gitlab_failed_jobs => :unknown,
          :github_released    => :unknown,
          :forge_released     => :unknown,
          #:rpm_released       => :unknown,
          :changelog_url      => :unknown,
        }
      end

      if @last_release_mods
        if @last_release_mods[project]
          last_version_in_simp = @last_release_mods[project]
        else
          last_version_in_simp = 'N/A'
        end
        entry[:version_last_simp_release] = last_version_in_simp
      end

      results[project] = entry
    end

    report_results(results)

    puts("STOP TIME: #{Time.now}")
    return 0
  rescue SignalException =>e
    if e.inspect == 'Interrupt'
      $stderr.puts "\nProcessing interrupted! Exiting."
    else
      $stderr.puts "\nProcess received signal #{e.message}. Exiting!"
      e.backtrace.first(10).each{|l| $stderr.puts l }
    end
    return 1
  rescue RuntimeError =>e
    $stderr.puts("ERROR: #{e.message}")
    return 1
  rescue => e
    $stderr.puts("\n#{e.message}")
    e.backtrace.first(10).each{|l| $stderr.puts l }
    return 1
  end

  def translate_status(status)
    case status
    when :released
      'Y'
    when :unreleased
      'N'
    when :tagged
      'tagged only'
    when :tagged_unknown_release_status
      'tagged but unknown release status'
    when :unknown_repo_moved
      'unknown: permanently moved repo'
    when :not_applicable
      'N/A'
    else
       status.to_s
    end
  end

end

####################################
if __FILE__ == $0
  reporter = SimpReleaseStatusGenerator.new
  exit reporter.run(ARGV)
end
