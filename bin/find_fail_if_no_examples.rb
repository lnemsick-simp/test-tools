#!/usr/bin/env ruby
require 'json'

projects_with_no_acceptance_helper = []
projects_with_fail = []
projects_without_fail = []
[ 'src/puppet/modules', 'src/assets'].each do |projects_dir|
  Dir.chdir(projects_dir) do
    Dir.glob('*').sort.each do |project_dir|
      next unless File.directory?(project_dir)
      project = File.basename(project_dir)
      metadata_file = File.join(project_dir,'metadata.json')
      if File.exist?(metadata_file)
        metadata = JSON.parse(File.read(metadata_file))
       next unless (metadata['name'].split('-')[0] == 'simp')
      end

      acceptance_helper = File.join(project_dir,'spec', 'spec_helper_acceptance.rb')
      if File.exist?(acceptance_helper)
        if IO.read(acceptance_helper).include?('c.fail_if_no_examples')
          projects_with_fail << project
        else
          projects_without_fail << project
        end
      else
        projects_with_no_acceptance_helper << project
      end
    end
  end
end


  puts
  puts '#'*80
  puts "#{projects_with_no_acceptance_helper.size} Projects with no spec_helper_acceptance.rb:\n  #{projects_with_no_acceptance_helper.sort.join("\n  ")}"
  puts
  puts "#{projects_with_fail.size} Projects with Rspec fail_if_no_examples:\n  #{projects_with_fail.sort.join("\n  ")}"
  puts
  puts "#{projects_without_fail.size} Projects without Rspec fail_if_no_examples:\n  #{projects_without_fail.sort.join("\n  ")}"
  puts
  puts "SUMMARY"
  total = projects_with_fail.size + projects_without_fail.size
  percent_complete = Float(projects_with_fail.size)/Float(total)*100.0
  puts "#{percent_complete} projects with spec_helper_acceptance.rb are configured"
