# Variables:
#
# SIMP_GEM_SERVERS | a space/comma delimited list of rubygem servers
# PUPPET_VERSION   | specifies the version of the puppet gem to load
gem_sources   = ENV.key?('SIMP_GEM_SERVERS') ? ENV['SIMP_GEM_SERVERS'].split(/[, ]+/) : ['https://rubygems.org']

gem_sources.each { |gem_source| source gem_source }

# In offline CI environments, the only copy of simp-rake-helpers will be in the
# local source tree.  Unless the SIMP_NO_LOCAL_RAKE_HELPERS environment variable
# is set, that path will be loaded if persent
simp_rake_helpers_opts = {}
path = './src/rubygems/simp-rake-helpers'
if File.directory?( path ) && ENV.fetch( 'SIMP_NO_LOCAL_RAKE_HELPERS', false )
  simp_rake_helpers_opts = { :path => path }
end


# mandatory gems
gem 'bundler'
gem 'coderay'
gem 'colorize'
gem 'dotenv'
gem 'gitlab'
gem 'jira-ruby'
gem 'json', '>= 2.3.0'
gem 'metadata-json-lint'
gem 'parallel'
gem 'puppet', ENV.fetch('PUPPET_VERSION', '~> 6')
gem 'puppet-lint'
gem 'puppet-strings'
gem 'puppetlabs_spec_helper'
gem 'net-telnet',['< 0.2.0']
gem 'rake'
gem 'ruby-progressbar'
gem 'simp-build-helpers', ENV.fetch('SIMP_BUILD_HELPERS_VERSION', '>= 0.1.0')
gem 'simp-rake-helpers', ENV.fetch('SIMP_RAKE_HELPERS_VERSION', ['>= 5.6.1', '< 6.0'])
#gem 'simp-rake-helpers', :path => './src/rubygems/rubygem-simp-rake-helpers'

group :system_tests do
  gem 'beaker'
  gem 'beaker-rspec'
  gem 'simp-beaker-helpers', ENV.fetch('SIMP_BEAKER_HELPERS_VERSION', ['>= 1.10.8', '< 2.0'])
end

# nice-to-have gems (for debugging)
group :debug do
  gem 'pry'
  gem 'pry-byebug'
  gem 'pry-doc'
end

#vim: set syntax=ruby:
