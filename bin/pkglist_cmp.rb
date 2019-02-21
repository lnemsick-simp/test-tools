#!/usr/bin/env ruby
#
require 'yaml'

iso_short_name = 'CentOS-7-1810'
iso_dir = '/mnt/iso/Packages'
pkglist = 'build/distributions/CentOS/7/x86_64/DVD/7-simp_pkglist.txt'
#iso_short_name = 'rhel-server-7.6'
#iso_dir = '/mnt/iso2/Packages'
#pkglist = 'build/distributions/RedHat/7/x86_64/DVD/7-simp_pkglist.txt'

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

puts "Loading #{pkglist}"
keep_pkgs = File.read(pkglist).split("\n")
keep_pkgs.delete_if { |line| (line[0] == '#') || line.strip.empty? }
puts "#{keep_pkgs.size} packages loaded"

iso_pkgs = iso_pkg_names.keys
keep_pkgs.each do |keep_pkg|
  matching_pkg =  iso_pkgs.find { |pkg| pkg == keep_pkg }
  unless matching_pkg
    puts "Keep package #{keep_pkg} does not exactly match any ISO packages" 
  end
end
