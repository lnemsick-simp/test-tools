#!/usr/bin/env ruby
require 'json'
require 'yaml'

projects_with_no_tests = []
projects_with_tests = []
projects_without_tests = []
[ 'src/puppet/modules', 'src/assets'].each do |projects_dir|
  Dir.chdir(projects_dir) do
    Dir.glob('*/.gitlab-ci.yml').each do |file|
      project = File.dirname(file)
      metadata_file = File.join(project,'metadata.json')
      if File.exist?(metadata_file)
        metadata = JSON.parse(File.read(metadata_file))
       next unless (metadata['name'].split('-')[0] == 'simp')
      end

      config = YAML.load(File.read(file))
      acceptance_tests = config.select { |key,value|
        (key != '.acceptance_base') &&
        value.is_a?(Hash) &&
        value.key?('stage') && (value['stage'] == 'acceptance')
      }
      if acceptance_tests.empty?
        projects_with_no_tests << project
        next
      end

      pup7_tests = acceptance_tests.select { |key,value| key.start_with?('pup7') }
      if pup7_tests.empty?
        projects_without_tests << project
      else
        projects_with_tests << project
        puts "#{project} Puppet 7 acceptance test jobs:"
        tests = {}
        pup7_tests.each do |test,test_info|
          tests[test] = test_info['script']
        end

        puts tests.to_yaml
        puts
      end
    end
  end
end


  puts
  puts '#'*80
  puts "#{projects_with_no_tests.size} Projects with no acceptance tests:\n  #{projects_with_no_tests.sort.join("\n  ")}"
  puts
  puts "#{projects_with_tests.size} Projects with at least 1 Puppet 7 acceptance test:\n  #{projects_with_tests.sort.join("\n  ")}"
  puts
  puts "#{projects_without_tests.size} Projects without Puppet 7 acceptance tests:\n  #{projects_without_tests.sort.join("\n  ")}"
  puts
