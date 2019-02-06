#!/usr/bin/env ruby
#
require 'fileutils'
require 'json'
require 'net/http'
require 'optparse'
require 'parallel'
require 'r10k/git'
require 'simp/componentinfo'

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
#          :git_source  => mod.repo.repo.origin,
#          :git_ref     => mod.repo.head,
#          :module_dir  => mod.basedir,
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
  FORGE_URL_BASE = 'https://forge.puppet.com/simp/'
  PCLOUD_URL_BASE = 'https://packagecloud.io/simp-project/6_X/packages/el/'

  def initialize

    @options = {
      :puppetfile              => nil,
      :last_release_puppetfile => nil,
      :root_dir                => File.expand_path('.'),
      :output_file             => 'simp_component_release_status.txt',
      :clean_start             => true,
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

  def get_git_info
    git_status = `git status`.split("\n").delete_if do |line|
      line.match(/HEAD detached at|On branch/).nil?
    end
    git_revision = git_status[0].gsub(/# HEAD detached at |# On branch /,'')
    git_origin_line = `git remote -v`.split("\n").delete_if do |line|
      line.match(/^origin/).nil? or line.match(/\(fetch\)/).nil?
    end
    git_origin = git_origin_line[0].gsub(/^origin/,'').gsub(/.fetch.$/,'').strip
    [git_origin, git_revision]
  end

  def get_changelog_url(info, git_origin)
    if info.type == :module
      changelog_url = "#{git_origin}/blob/master/CHANGELOG"
    else
      spec_files = Dir.glob(File.join(info.component_dir, 'build', '*.spec'))
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
    (result.code == '200')
  end

  def get_forge_status(info)
    if info.type == :module
      url = FORGE_URL_BASE + "#{File.basename(info.component_dir)}/#{info.version}/readme"
      forge_published = (url_exists?(url)) ? :released : :unreleased
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

  def get_release_status(info, git_origin)
    tag_found = false
    Dir.chdir(info.component_dir) do
    # determine if latest version is tagged
      `git fetch -t origin 2>/dev/null`
      tags = `git tag -l`.split("\n")
      debug("Available tags from origin = #{tags}")
      tag_found = tags.include?(info.version)
    end
    if (tag_found)
      if @github_api_limit_reached
        # No point trying to curl results...
        :tagged_unknown_release_status
      else
        project_name = git_origin.split('/').last
        releases_url = "https://api.github.com/repos/simp/#{project_name}/releases/tags/#{info.version}"
        releases_url += "?access_token=#{ENV['GITHUB_ACCESS_TOKEN']}" if ENV['GITHUB_ACCESS_TOKEN']
        github_release_results = JSON.parse(`curl -XGET #{releases_url} -s`)
        debug(github_release_results.to_s)
        if github_release_results.key?('tag_name')
          :released
        else
          if github_release_results['message'] and github_release_results['message'].match(/Not Found/i)
            :tagged
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

  def get_rpm_status(info)
    if info.type == :module
      # query PackageCloud to see if a release to both el6 and el7 repos has been made
      #FIXME This ASSUMES release qualifier is '0'
      url_el6 = PCLOUD_URL_BASE + "6/pupmod-simp-#{File.basename(info.component_dir)}-0.noarch.rpm"
      url_el7 = PCLOUD_URL_BASE + "7/pupmod-simp-#{File.basename(info.component_dir)}-0.noarch.rpm"
      rpms_found = url_exists?(url_el6) && url_exists?(url_el7)
      rpms_released = rpms_found ? :released : :unreleased
    else
      rpms_released = :tbd
    end
    rpms_released
  end

  def get_simp_owned_modules
    modules_dir = File.join(@options[:root_dir], 'src', 'puppet', 'modules')
    simp_modules = []

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
    assets = Dir.entries(assets_dir).delete_if { |dir| dir[0] == '.' }
    assets.map! { |asset| File.expand_path(File.join(assets_dir, asset)) }
    assets.sort
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

    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename(__FILE__)} [options] -p PUPPETFILE"
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
      'Latest Version',
      'Unit Test Status',
      'Acceptance Test Status',
      'GitHub Released',
      'Forge Released',
      'RPM Released',
      'Changelog'
    ]
    info(columns.compact.join(','))
    results.each do |project, info|
      project_data = [
        project,
        info[ :latest_version],
        (@last_release_mods.nil?) ? nil : info[:version_last_simp_release],
        info[ :latest_version],
        'TBD',
        'TBD',
        translate_status(info[:github_released]),
        translate_status(info[:forge_released]),
        translate_status(info[:rpm_released]),
        info[:changelog_url],
      ]
      info(project_data.compact.join(','))
    end
  end

  def run(args)
    parse_command_line(args)
    return 0 if @options[:help_requested] # already have logged help

    if ENV['GITHUB_ACCESS_TOKEN'].nil?
      msg = <<EOM
GITHUB_ACCESS_TOKEN environment variable not detected.

  GitHub queries may be rate limited, which will prevent
  this program from determining GitHub release status.
  Obtain an GitHub OAUTH token, set GITHUB_ACCESS_TOKEN
  to it, and re-run for best results.

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
        info = Simp::ComponentInfo.new(project_dir, true, @options[:verbose])
        git_origin = nil
        Dir.chdir(info.component_dir) do
          git_origin, git_revision = get_git_info
        end
        entry = {
          :latest_version  => info.version,
          :github_released => get_release_status(info, git_origin),
          :forge_released  => get_forge_status(info),
          :rpm_released    => get_rpm_status(info),
          :changelog_url   => get_changelog_url(info, git_origin)
        }
      rescue => e
        warning("#{project}: #{e}")
        debug(e.backtrace.join("\n"))
        entry = {
          :latest_version  => :unknown,
          :github_released => :unknown,
          :forge_released  => :unknown,
          :rpm_released    => :unknown,
          :changelog_url   => :unknown,
        }
      end

      if @last_release_mods
        if @last_release_mods[project]
          last_version_in_simp = @last_release_mods[project]
        else
          last_version_in_simp = 'n/a'
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
