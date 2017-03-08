#!/usr/bin/env ruby

def log(message, logfile)
  puts message
  File.open(logfile, 'a') { |file| file.puts message }
end

simp_core_root_dir = (ARGV[0] ? ARGV[0] : File.expand_path('.'))

assets = {
  'simp-adapter'     => :simp,
  'simp-environment' => :simp,
  'simp-utils'       => :simp
}

puppet_modules = {
  'acpid'                      => :simp,
  'activemq'                   => :simp,
  'aide'                       => :simp,
  'apache'                     => :external,
  'at'                         => :simp,
  'auditd'                     => :simp,
  'augeasproviders'            => :external,
  'augeasproviders_apache'     => :external,
  'augeasproviders_base'       => :external,
  'augeasproviders_core'       => :external,
  'augeasproviders_grub'       => :external,
  'augeasproviders_mounttab'   => :external,
  'augeasproviders_nagios'     => :external,
  'augeasproviders_pam'        => :external,
  'augeasproviders_postgresql' => :external,
  'augeasproviders_puppet'     => :external,
  'augeasproviders_shellvar'   => :external,
  'augeasproviders_ssh'        => :external,
  'augeasproviders_sysctl'     => :external,
  'autofs'                     => :simp,
  'chkrootkit'                 => :simp,
  'clamav'                     => :simp,
  'compliance_markup'          => :simp,
  'concat'                     => :simp,  # when changes are merged upstream goes back to :external
  'cron'                       => :simp,
  'datacat'                    => :external,
  'dhcp'                       => :simp,
  'dirtycow'                   => :simp,
  'elasticsearch'              => :external,
  'file_concat'                => :external,
  'fips'                       => :simp,
  'freeradius'                 => :simp,
  'gdm'                        => :simp,
  'gnome'                      => :simp,
  'gpasswd'                    => :simp,
  'grafana'                    => :external,
  'haveged'                    => :simp,
  'incron'                     => :simp,
  'inifile'                    => :external,
  'iptables'                   => :simp,
  'issue'                      => :simp,
  'java'                       => :external,
  'java_ks'                    => :external,
  'jenkins'                    => :simp,
  'journald'                   => :simp,
  'kmod'                       => :external,
  'krb5'                       => :simp,
  'libreswan'                  => :simp,
  'libvirt'                    => :simp,
  'logrotate'                  => :simp,
  'logstash'                   => :external,
  'mcafee'                     => :simp,
  'mcollective'                => :simp,
  'motd'                       => :external,
  'mozilla'                    => :simp,
  'mysql'                      => :external,
  'named'                      => :simp,
  'network'                    => :simp,
  'nfs'                        => :simp,
  'nsswitch'                   => :simp,
  'ntpd'                       => :simp,
  'oddjob'                     => :simp,
  'openscap'                   => :simp,
  'pam'                        => :simp,
  'pki'                        => :simp,
  'polkit'                     => :simp,
  'postfix'                    => :simp,
  'postgresql'                 => :external,
  'pupmod'                     => :simp,
  'puppetdb'                   => :simp,
  'resolv'                     => :simp,
  'rsync'                      => :simp,
  'rsyslog'                    => :simp,
  'selinux'                    => :simp,
  'simp'                       => :simp,
  'simp_apache'                => :simp,
  'simpcat'                    => :simp,
  'simp_elasticsearch'         => :simp,
  'simp_grafana'               => :simp,
  'simplib'                    => :simp,
  'simp_logstash'              => :simp,
  'simp_nfs'                   => :simp,
  'simp_openldap'              => :simp,
  'simp_options'               => :simp,
  'simp_rsyslog'               => :simp,
  'site'                       => :simp,
  'ssh'                        => :simp,
  'sssd'                       => :simp,
  'stdlib'                     => :external,
  'stunnel'                    => :simp,
  'sudo'                       => :simp,
  'sudosh'                     => :simp,
  'svckill'                    => :simp,
  'swap'                       => :simp,
  'tcpwrappers'                => :simp,
  'tftpboot'                   => :simp,
  'timezone'                   => :simp,
  'tpm'                        => :simp,
  'tuned'                      => :simp,
  'upstart'                    => :simp,
  'useradd'                    => :simp,
  'vnc'                        => :simp,
  'vsftpd'                     => :simp,
  'xinetd'                     => :simp
}

ruby_gems = { 'simp_cli' => :simp }

other = {
  'doc'   => :simp,
  'rsync' => :simp
}

projects = []
projects << simp_core_root_dir  # simp-core itself

assets.each { |name,owner|
  projects << File.join(simp_core_root_dir, 'src', 'assets', name) if owner == :simp
}

puppet_modules.each { |name,owner|
  projects << File.join(simp_core_root_dir, 'src', 'puppet', 'modules', name) if owner == :simp
}

ruby_gems.each { |name,owner|
  projects << File.join(simp_core_root_dir, 'src', 'rubygems', name) if owner == :simp
}

other.each { |name,owner|
  projects << File.join(simp_core_root_dir, 'src', name) if owner == :simp
}

timestamp = Time.now.to_i
logfile = File.join(simp_core_root_dir, "test-#{timestamp}.log")
projects.each { |project|
  next unless Dir.exists?(File.join(project, 'spec'))
  
  ref = `git show-ref --head | head -n 1`.split[0]
  log("Processing #{project} ref #{ref}", logfile)
  Dir.chdir(project) do
    log("  Updating ruby gems", logfile)
    `bundle update >> #{logfile} 2>&1`
    if $?.exitstatus != 0
      log("  FAILED: 'bundle update' for #{project}", logfile)
      next
    end
   
    log("  Running spec tests", logfile)
    `bundle exec rake spec >> #{logfile} 2>&1`
    if $?.exitstatus == 0
      log("  --> PASSED: 'bundle exec rake spec' for #{project}", logfile)
    else
      log("  --> FAILED: 'bundle exec rake spec' for #{project}", logfile)
    end

    if Dir.exists?(File.join(project, 'spec', 'acceptance', 'suites'))
      # TODO what about different suites? Not all projects have a metadata.yml file
      # that turns alternate test suites on or off
      # Manually did the following copies to enable tests:
# cp nfs/spec/acceptance/suites/stunnel/metadata.yml simp_apache/spec/acceptance/suites/htaccess
# cp nfs/spec/acceptance/suites/stunnel/metadata.yml simp_logstash/spec/acceptance/suites/elasticsearch
# cp nfs/spec/acceptance/suites/stunnel/metadata.yml simp/spec/acceptance/suites/base_apps
# cp nfs/spec/acceptance/suites/stunnel/metadata.yml simp/spec/acceptance/suites/mcollective
# cp nfs/spec/acceptance/suites/stunnel/metadata.yml simp/spec/acceptance/suites/no_simp_server
      command = 'beaker:suites'
    else
      command = 'acceptance'
    end

    log("  Running acceptance tests", logfile)
    `bundle exec rake #{command} >> #{logfile} 2>&1`
    if $?.exitstatus == 0
      log("  --> PASSED: 'bundle exec rake #{command}' for #{project}", logfile)
    else
      log("  --> FAILED: 'bundle exec rake #{command}' for #{project}", logfile)
    end

    log('', logfile)
  end
}
