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
          :desired_ref => mod.desired_ref,
          :r10k_module => mod,
          :r10k_cache  => mod.repo.repo.cache_repo
        }
      end
    end
  end
end


class ReferenceMdStatusGenerator

  class InvalidModule < StandardError; end

  def initialize

    @options = {
      :puppetfile              => nil,
      :root_dir                => File.expand_path('.'),
      :output_file             => 'simp_module_reference_md_status.csv',
      :clean_start             => true,
      :verbose                 => false,
      :help_requested          => false
    }
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

  def get_git_info
    git_ref = `git log -n 1 --format=%H`.strip
    git_origin_line = `git remote -v`.split("\n").delete_if do |line|
      line.match(/^origin/).nil? or line.match(/\(fetch\)/).nil?
    end
    git_origin = git_origin_line[0].gsub(/^origin/,'').gsub(/.fetch.$/,'').strip
    [git_origin, git_ref]
  end

  def reference_md_current?
    return :missing unless File.exist?('REFERENCE.md')

    debug("Checking for REFERENCE.md updates in #{Dir.pwd}")

    `bundle update; bundle exec puppet strings generate --format markdown --out REFERENCE.md 2>&1`
    if $?.exitstatus and $?.exitstatus != 0
      warning("REFERENCE.md in #{Dir.pwd} could not be generated")
      return :failed_to_generate
    end

    status = `git status --porcelain REFERENCE.md`
    current = nil
    if status.match(/^\s*M\s+REFERENCE.md/).nil?
      current = true
    else
      current = false
      debug('Differences in REFERENCE.md found:')
      difference = `git diff REFERENCE.md`.split("\n")
      difference.delete_if { |line| !(line[0] == '-' || line[0] == '+') }
      difference.delete_if { |line| line.include?('REFERENCE.md') }
      debug(difference.join("\n"))
    end

    current
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

  def load_module_metadata( file_path = nil )
    require 'json'
    begin
      JSON.parse(File.read(File.join(file_path, 'metadata.json')))
    rescue => e
      raise InvalidModule.new(e.message)
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
      opts.banner = "Usage: #{program} [OPTIONS] -p PUPPETFILE"
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
      'Git Ref',
      'Version',
      'REFERENCE.md Current'
    ]
    info(columns.compact.join(','))
    results.each do |project, proj_info|
      project_data = [
        project,
        proj_info[:git_ref],
        proj_info[:latest_version],
        proj_info[:reference_md_current]
      ]
      info(project_data.compact.join(','))
    end
  end

  def run(args)
    parse_command_line(args)
    return 0 if @options[:help_requested] # already have logged help

    debug("Running with options = <#{args.join(' ')}>") unless args.empty?
    debug("Internal options=#{@options}")
    puts("START TIME: #{Time.now}")

    check_out_projects if @options[:clean_start]

    results = {}
    get_simp_owned_modules.each do |project_dir|
      project = File.basename(project_dir)
      debug('='*80)
      debug("Processing '#{project}'")
      begin
        proj_info = nil
        git_origin = nil
        git_ref = nil
        reference_md_current = nil
        Dir.chdir(project_dir) do
          proj_info = Simp::ComponentInfo.new(project_dir, true, @options[:verbose])
          git_origin, git_ref = get_git_info
          reference_md_current = reference_md_current?
        end

        entry = {
          :latest_version       => proj_info.version,
          :git_ref              => git_ref,
          :reference_md_current => reference_md_current
        }
      rescue => e
        warning("#{project}: #{e}")
        debug(e.backtrace.join("\n"))
        entry = {
          :latest_version       => :unknown,
          :git_ref              => :unknown,
          :reference_md_current => :unknown
        }
      end

      results[project] = entry
    end

#require 'pry-byebug'
#binding.pry

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

end

####################################
if __FILE__ == $0
  reporter = ReferenceMdStatusGenerator.new
  exit reporter.run(ARGV)
end
