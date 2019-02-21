#!/usr/bin/env ruby
#
require 'yaml'

#iso_short_name = 'CentOS-7-1810'
#iso_dir = '/mnt/iso/Packages'
#packages_yaml = 'build/distributions/CentOS/7/x86_64/yum_data/packages.yaml'
iso_short_name = 'rhel-server-7.6'
iso_dir = '/mnt/iso2/Packages'
packages_yaml = 'build/distributions/RedHat/7/x86_64/yum_data/packages.yaml'

iso_pkgs_file = "#{iso_short_name}_packages.txt"

iso_pkg_names = {}
if File.exist?(iso_pkgs_file)
  puts "Loading #{iso_short_name} package names"
  IO.readlines(iso_pkgs_file).each do |line|
    name,rpm_name = line.split
    iso_pkg_names[name] = rpm_name
  end
  puts "#{iso_pkg_names.size} package names loaded"
else
  puts "Extracting #{iso_short_name} package names from #{iso_dir}"
  iso_rpms = Dir.glob("#{iso_dir}/*rpm").sort
  iso_rpms.each do |rpm_name|
    name =`rpm -qp #{rpm_name} --queryformat '%{NAME}\n'`.strip
    iso_pkg_names[name] = File.basename(rpm_name)
  end

  File.open(iso_pkgs_file, 'w') do |file|
    iso_pkg_names.each do |name, rpm_name|
      file.puts "#{name} #{rpm_name}"
    end
  end
  puts "#{iso_pkg_names.size} package names extracted"
end

puts "Loading #{packages_yaml}"
packages = YAML.load(File.read(packages_yaml))
puts "#{packages.size} packages loaded"

packages.each do |key, info|
  unless info[:rpm_name] =~ /^#{key}/
    $stderr.puts "ERROR: packages.yaml key #{key} mismatches :rpm_name #{info[:rpm_name]}"
  end
end

package_keys = packages.keys.sort

iso_pkg_names.each do |name, rpm_name|
  matching_pkgs =  package_keys.find_all { |key| key =~ /^#{name}/ }
  unless matching_pkgs.empty?
    puts "Potential duplicate: ISO #{rpm_name} <-> packages.yaml #{matching_pkgs}"
  end
end
