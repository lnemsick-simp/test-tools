#!/usr/bin/env ruby
require 'json'

dep_to_find = ARGV[0]
dep_to_find_alt = dep_to_find.gsub('/','-')

skip_simp = true
skip_non_simp = false

modules = []
Dir.glob("*/metadata.json").each do |metadata_file|
  metadata = JSON.parse(File.read(metadata_file))
  if skip_simp
    next if (metadata['name'].split('-')[0] == 'simp')
  end

  if skip_non_simp
    next unless (metadata['name'].split('-')[0] == 'simp')
  end

  found = false
  metadata['dependencies'].each do |dep|
    if (dep['name'] == dep_to_find) || (dep['name'] == dep_to_find_alt)
      found = true
      break
    end
  end

  unless found && !skip_simp
    if metadata.key?('simp')
      metadata['simp']['optional_dependencies'].each do |dep|
        if dep['name'] == dep_to_find
          found = true
          break
        end
      end
    end
  end
  modules << File.dirname(metadata_file) if found
end

if modules.empty?
  puts "No modules require #{dep_to_find}"
else
  puts "Modules that require #{dep_to_find}:\n  #{modules.sort.join("\n  ")}"
end

