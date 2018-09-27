#!/usr/bin/env ruby
#

require 'fileutils'

def copy_arch_rpms(source_dir, dest_dir, arch, verbose)
  arch_rpms = Dir.glob(File.join(source_dir, arch, '*.rpm'))
  unless arch_rpms.empty?
    dest_arch_dir = File.join(dest_dir, arch)
    puts '='*80 if verbose
    puts "Copying files from #{source_dir} to #{dest_arch_dir}" if verbose
    FileUtils.mkdir_p(dest_arch_dir)
    arch_rpms.each do |rpm| 
      dest_rpm = File.join(dest_arch_dir, File.basename(rpm))
      if File.exist?(dest_rpm)
        puts "WARNING:  Copy skipped:  #{dest_rpm} exists"
      else
        FileUtils.cp(rpm, dest_arch_dir, :verbose => verbose)
      end
    end
  end
  arch_rpms.size
end

def copy_and_link_noarch_rpms(source_dir, dest_dir, arch, verbose)
  noarch_rpms = Dir.glob(File.join(source_dir, 'noarch', '*.rpm'))
  unless noarch_rpms.empty?
    dest_noarch_dir = File.join(dest_dir, 'noarch')
    dest_arch_dir = File.join(dest_dir, arch)
    puts '='*80 if verbose
    puts "Copying files from #{source_dir} to #{dest_noarch_dir} and linking" if verbose
    FileUtils.mkdir_p(dest_noarch_dir)
    noarch_rpms.each do |rpm|
      dest_rpm = File.join(dest_noarch_dir, File.basename(rpm))
      if File.exist?(dest_rpm)
        puts "WARNING:  Copy skipped:  #{dest_rpm} exists"
      else
        FileUtils.cp(rpm, dest_noarch_dir, :verbose => verbose)
      end
      dest_link = File.join(dest_arch_dir, File.basename(rpm))
      if File.exist?(dest_link)
        puts "WARNING:  Link skipped:  #{dest_link} exists"
      else
        FileUtils.ln_s(dest_rpm, dest_link, :verbose => verbose)
      end
    end
  end
  noarch_rpms.size
end

def create_arch_repo(dest_dir, arch, verbose)
  dest_arch_dir = File.join(dest_dir, arch)
  puts '='*80 if verbose
  puts "Creating repo in #{dest_arch_dir}" if verbose
  Dir.chdir(dest_arch_dir) do
    puts `createrepo . 2>&1`
    status = $?
    fail("createrepo failed in #{dest_arch_dir}") if status.exitstatus != 0
  end
end

def fix_repo_perms(dest_dir, verbose)
  puts '='*80 if verbose
  puts "Fixing permissions in #{dest_dir} and rebuilding yum cache" if verbose
  FileUtils.chown_R('root', 'apache', dest_dir) if ENV['USER'] == 'root'
  Dir.chdir(dest_dir) do
    `find . -type f -exec chmod 640 {} \\; `
    `find . -type d -exec chmod 750 {} \\; `
    puts `yum clean all; yum makecache 2>&1`
  end
end

source_dir = File.expand_path(ARGV[0])
dest_dir = File.expand_path(ARGV[1])
arch = ARGV[2].nil? ? 'x86_64' : ARGV[2]
verbose = true

puts "Copying files from #{source_dir} to #{dest_dir}" if verbose

num_rpms = copy_arch_rpms(source_dir, dest_dir, arch, verbose)
num_rpms += copy_and_link_noarch_rpms(source_dir, dest_dir, arch, verbose)

if num_rpms > 0
  create_arch_repo(dest_dir, arch, verbose)
  fix_repo_perms(dest_dir, verbose)
end
