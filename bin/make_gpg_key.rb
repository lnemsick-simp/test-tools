#!/usr/bin/env ruby
require 'date'
require 'fileutils'
require 'securerandom'

key_name = ARGV[0] ? ARGV[0] : 'liztest'
root_dir = ARGV[1] ? ARGV[1] : '.'
key_age_days = ARGV[2] ? ARGV[2] : 365

key_dir = File.expand_path(File.join(root_dir, key_name))
FileUtils.mkdir_p(key_dir)
FileUtils.chmod(0700,key_dir)

Dir.chdir(key_dir) do
  dev_email = "#{key_name}@simp.development.key"
  current_key = `gpg --homedir=#{Dir.pwd} --list-keys #{dev_email} 2>/dev/null`
  days_left = 0
  unless current_key.empty?
    lasts_until = current_key.lines.first.strip.split("\s").last.delete(']')
    days_left = (Date.parse(lasts_until) - DateTime.now).to_i
  end

  if days_left > 0
    puts "GPG key for #{key_name} exists and will expire in #{days_left} days."
  else
    puts "Generating new GPG key"

    Dir.glob('*').each do |todel|
      FileUtils.rm_rf(todel)
    end

    expire_date = (DateTime.now + key_age_days)
    now = Time.now.to_i.to_s
    dev_email = "#{key_name}@simp.development.key"
    passphrase = SecureRandom.base64(500)

    gpg_infile = <<-EOM
        %echo Generating #{key_name} Development GPG Key
        %echo
        %echo This key will expire on #{expire_date}
        %echo
        Key-Type: RSA
        Key-Length: 4096
        Key-Usage: sign
        Name-Real: SIMP #{key_name} Development
        Name-Comment: #{key_name} development key #{now}
        Name-Email: #{dev_email}
        Expire-Date:#{key_age_days}d 
        Passphrase: #{passphrase}
        %pubring pubring.gpg
        %secring secring.gpg
        # The following creates the key, so we can print "Done!" afterwards
        %commit
        %echo New GPG #{key_name} Development Key Created
    EOM

    gpg_agent_script = <<-EOM
        #!/bin/sh

        gpg-agent --homedir=#{Dir.pwd} --batch --daemon --pinentry-program /usr/bin/pinentry-curses < /dev/null &
    EOM

    File.open('gengpgkey','w'){ |fh| fh.puts(gpg_infile) }
    File.open('run_gpg_agent','w'){ |fh| fh.puts(gpg_agent_script) }
    FileUtils.chmod(0755,'run_gpg_agent')

    gpg_agent_pid = nil
    gpg_agent_socket = nil

    if File.exist?(%(#{ENV['HOME']}/.gnupg/S.gpg-agent))
      gpg_agent_socket = %(#{ENV['HOME']}/.gnupg/S.gpg-agent)
      gpg_agent_socket = %(#{ENV['HOME']}/.gnupg/S.gpg-agent)
    end

    begin
      unless gpg_agent_socket
        gpg_agent_output = %x(./run_gpg_agent).strip

        if gpg_agent_output.empty?
          # This is a working version of gpg-agent, that means we need to
          # connect to it to figure out what's going on

          gpg_agent_socket = %(#{Dir.pwd}/S.gpg-agent)
          gpg_agent_pid_info = %x(gpg-agent --homedir=#{Dir.pwd} /get serverpid).strip
          gpg_agent_pid_info =~ %r(\[(\d+)\])
          gpg_agent_pid = $1
        else
          # Are we running a broken version of the gpg-agent? If so, we'll
          # get back info on the command line.

          gpg_agent_info = gpg_agent_output.split(';').first.split('=').last.split(':')
          gpg_agent_socket = gpg_agent_info[0]
          gpg_agent_pid = gpg_agent_info[1].strip.to_i

          unless File.exist?(%(#{Dir.pwd}/#{File.basename(gpg_agent_socket)}))
            ln_s(gpg_agent_socket,%(#{Dir.pwd}/#{File.basename(gpg_agent_socket)}))
          end
        end
      end

      %x{gpg --homedir=#{Dir.pwd} --batch --gen-key gengpgkey}
      %x{gpg --homedir=#{Dir.pwd} --armor --export #{dev_email} > RPM-GPG-KEY-SIMP-#{key_name}-Dev}
      generated = true
    ensure
      begin
        rm('S.gpg-agent') if File.symlink?('S.gpg-agent')

        if gpg_agent_pid
          Process.kill(2,gpg_agent_pid)
          Process.wait(gpg_agent_pid)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        # Not Running, Nothing to do!
      end
    end
  end
end


