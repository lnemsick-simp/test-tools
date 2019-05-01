#!/usr/bin/env ruby
require 'gitlab'
require 'colorize'
require 'optparse'

# Array or regexes
SKIPPED_PROJECTS = [
  /activemq/,
  /augeasproviders/,
  /binford2k-node_encrypt/,
  /jenkins/,
  /puppetlabs-/,
  /puppet-/,
  /mcollective/
]

#FIXME Need to figure out how to extract whether test is skipped from
# gitlab API.  Info is in gitlab-ci.yaml, but haven't found it in results
# pulled back by API, yet
SKIPPED_TESTS = {
#  'validation' => [ 'pup6-lint', 'pup6-unit' ]
}


# return the status of the pipeline, colored appropriately
def color_pipeline_status(pipeline)
  def pad(s)
    return "%-8s" % s
  end

  if pipeline.respond_to? :status
    $stats[pipeline.status] += 1
    case pipeline.status
    when 'running'
      pad('running').yellow.bold
    when 'pending'
      pad('created').blue
    when 'success'
      pad('success').green
    when 'failed'
      pad('failed').red.bold
    when 'skipped'
      pad('skipped').yellow
    when 'created'
      pad('created').blue
    when 'canceled'
      pad('canceled').bold
    when 'none'
      pad('none').cyan
    else
      pad(pipeline.status).colorize(background: :red)
    end
  else
    $stats['none'] += 1
    pad('none').yellow
  end
end

def pipeline_status(data, colorize=true)
  status = color_pipeline_status(data[:pipeline])
  status = status.uncolorize  unless colorize
  failed_jobs = {}
  create_times = []
  unless status =~ /none/
    data[:jobs].each do |job|
      create_times << job.created_at
      if status =~ /failed/
        if job.status == 'failed'
          next if SKIPPED_TESTS[job.stage] && SKIPPED_TESTS[job.stage].include?(job.name)
          unless failed_jobs.key?(job.stage)
            failed_jobs[job.stage] = []
          end
          failed_jobs[job.stage] << job.name
        end
      end
    end
  end
  stage_failures = []
  failed_jobs.each_key do |stage|
   stage_failures << "#{stage}:#{failed_jobs[stage].join(',')}"
  end
  [status, create_times.sort.first, stage_failures.join(';')]
end

# find the latest pipeline, on any branch
def latest_pipeline(pipelines)
  pipelines.max_by{|p| p.id }
end

# find the latest pipeline on the master branch
def master_pipeline(pipelines)
  pipelines \
    .select {|p| p.ref == 'master' } \
    .max_by{|p| p.id }
end

# find the latest pipeline on a tag
def latest_tag_pipeline(proj, pipelines)
  begin
    tags = g.tags(proj.id)
    latest_tag = tags.first.name
    pipelines.select {|p| p.ref == latest_tag}.first
  rescue
    nil
  end
end

# remove projects with names that match the contant
def filter_pipelines(list,to_skip)
  list.reject{ |e| to_skip.any? { |re| re =~ e } }
end

def get_pipeline(type, pipelines)
  pipeline = nil
  case type
  when 'master'
    pipeline = master_pipeline(pipelines)
  when 'latest'
    pipeline = latest_pipeline(pipelines)
  when 'latest-tag'
    pipeline = latest_tag_pipeline(proj, pipelines)
  end
  pipeline
end

###############  main ###################

time_start = Time.now

$options = {
  :colorize  => true,
  :endpoint  => (ENV['GITLAB_URL'] || 'https://gitlab.com/api/v4'),
  :org       => 'simp',
  :report_on => 'master',
  :debug     => false
}

OptionParser.new do |opts|
  program = File.basename(__FILE__)
  opts.banner = [
    "Usage: #{program} [OPTIONS] -t USER_GITLAB_API_TOKEN",
    "       GITLAB_TOKEN=USER_GITLAB_API_TOKEN #{program} [OPTIONS]"
  ].join("\n")

  opts.separator("\n")

  opts.on('-c', '--[no-]colorize',
    'Color-code status',
    "Defaults to #{$options[:colorize] ? 'color-coded': 'not color-coded'}") do |c|
    $options[:colorize] = c
  end

  opts.on('-o', '--org=val', String,
    'GitLab org to query against.',
    "Defaults to '#{$options[:org]}'") do |o|
    $options[:org] = o
  end

  opts.on('-p', '--pipeline=val', String,
    'Which pipeline to grab: latest, latest-tag, or master',
    "Defaults to '#{$options[:report_on]}'") do |p|
    $options[:report_on] = p
  end

  opts.on('-t', '--token=val', String, 'GitLab API token') do |t|
    $options[:token] = t
  end

  opts.on('-e', '--endpoint=val', String, 
    'GitLab API endpoint',
    "Defaults to #{$options[:endpoint]}") do |e|
    $options[:endpoint] = e
  end

  opts.on('-v', '--[no-]verbose', 'Run verbosely') do |v|
    $options[:verbose] = v
  end

  opts.on('-h', '--help', 'Print this menu') do
    puts opts
    exit
  end
end.parse!

# allow environment variables for these two options in particular
unless $options[:token]
  $options[:token] = ENV['GITLAB_TOKEN']
end

# connect to gitlab
g = Gitlab.client(
  endpoint: $options[:endpoint],
  private_token: $options[:token]
)

threads = []
org_pipelines = {}
# gitlab makes you take results in pages
# it doesn't really matter if you ask for too many pages, the extras will return empty
(1..8).each do |page|
#  threads << Thread.new do
    puts "Retrieving #{$options[:org]} project list page #{page}" if $options[:debug]
#    org_projects_page = g.group_projects($options[:org], page: page) || []
    org_projects_page = g.group_projects($options[:org], page: page)
    if org_projects_page
      org_projects = org_projects_page
    else
puts "EMPTY PAGE RETURNED #{org_projects_page.inspect}"
      org_projects = []
    end
    org_projects.each do |proj|
      puts ">> Retrieving #{proj.name} pipelines" if $options[:debug]
      pipelines = g.pipelines(proj.id)
      pipeline = get_pipeline($options[:report_on], pipelines)
      if pipeline
        puts ">>>> Retrieving #{proj.name} pipeline jobs" if $options[:debug]
        jobs = g.pipeline_jobs(proj.id, pipeline.id)
      else
        jobs = nil
      end

      org_pipelines[proj.name] = {
        project: proj,
        pipeline: pipeline,
        jobs: jobs
      }
    end
#  end
end

#threads.each(&:join)

$stats = Hash.new(0)

relevant_pipelines = filter_pipelines(org_pipelines,SKIPPED_PROJECTS)
results = []
relevant_pipelines.each do |proj_name, data|
  longest_name = relevant_pipelines.keys.map(&:length).max
  longest_url = relevant_pipelines.values.map { |data| data[:pipeline].nil? ? 0 : data[:pipeline].web_url.length }.max

  # each line should look like this
  # project name - test status - pipeline url
  #   >> OR (pipeline failure) <<
  # project name - test status - pipeline url - failed test list
  status,create_time, failed_job_list = pipeline_status(data, $options[:colorize])
  result = [
    "%-#{longest_name}s" % proj_name,
    status,
    create_time,
    data[:pipeline].nil? ? ' '*longest_url : "%-#{longest_url}s" % data[:pipeline].web_url,
    failed_job_list
  ]
  results << result
end

results.sort! { |result1,result2| result1[0] <=> result2[0] }
results.each { |result| puts result.join('   ') }

term_width = `tput cols`.to_i
puts '='*term_width
time_finish = Time.now
$stats['time'] = (time_finish - time_start).round(1).to_s + " seconds"
$stats.each do |stat,value|
  puts stat.capitalize + ': ' + value.to_s
end
