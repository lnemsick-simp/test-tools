#!/usr/bin/env ruby
require 'gitlab'
require 'optparse'

#time_start = Time.now

$options = {
  :endpoint           => (ENV['GITLAB_URL'] || 'https://gitlab.com/api/v4'),
  :org                => 'simp',
  :branch             => 'master',
  :pipeline_variables => {
    'SIMP_FORCE_RUN_MATRIX' => 'yes',
    'SIMP_MATRIX_LEVEL'     => 2
   },
  :verbose            => false
}

OptionParser.new do |opts|
  program = File.basename(__FILE__)
  opts.banner = [
    "Usage: #{program} [OPTIONS] -t USER_GITLAB_API_TOKEN",
    "       GITLAB_TOKEN=USER_GITLAB_API_TOKEN #{program} [OPTIONS]"
  ].join("\n")

  opts.separator("\n")

  opts.on('-o', '--org=val', String,
    'GitLab org to query against.',
    "Defaults to '#{$options[:org]}'") do |o|
    $options[:org] = o
  end

  opts.on('-p', '--project=val', String,
    'Name of project') do |project|
    $options[:project] = project
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

unless $options[:token]
  if ENV['GITLAB_TOKEN']
    $options[:token] = ENV['GITLAB_TOKEN']
  else
    fail('GITLAB_TOKEN must be set')
  end
end

# connect to gitlab
gitlab_client = Gitlab.client(
  :endpoint      => $options[:endpoint],
  :private_token => $options[:token]
)

begin
  proj = gitlab_client.project("#{$options[:org]}/#{$options[:project]}")
  puts "Creating pipeline for #{proj.name}"
  gitlab_client.create_pipeline(proj.id, $options[:branch], $options[:pipeline_variables])
rescue Exception => e
  # can happen if a GitLab project for the component does not exist
  fail("Unable to create pipeline for '#{$options[:project]}':\n  #{e.message}")
end
