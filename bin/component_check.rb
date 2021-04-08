#!/usr/bin/env ruby
#

require 'net/http'

mod_name = 'auditd'
mod_version = '7.1.3'

github_endpoint = "https://github.com/simp/pupmod-simp-#{mod_name}/releases/tag/#{mod_version}"
github_uri = URI.parse(github_endpoint)
github_query = Net::HTTP.new(github_uri.host, github_uri.port)
github_query.use_ssl = true
# HEAD request doesn't return the body of the request, only a return code
github_res = github_query.request_head(github_uri.path)
puts "GitHub: #{github_res.code}"

packagecloud_endpoint = "https://packagecloud.io/simp-project/6_X/packages/el/6/pupmod-simp-#{mod_name}-#{mod_version}-0.noarch.rpm"
packagecloud_uri = URI.parse(packagecloud_endpoint)

packagecloud_query = Net::HTTP.new(packagecloud_uri.host, packagecloud_uri.port)
packagecloud_query.use_ssl = true
packagecloud_res = packagecloud_query.request_head(packagecloud_uri.path)
puts "PackageCloud: #{packagecloud_res.code}"

forge_endpoint = "https://forge.puppet.com/simp/#{mod_name}/#{mod_version}/readme"
forge_uri = URI.parse(forgeud_endpoint)
forge_query = Net::HTTP.new(forge_uri.host, forge_uri.port)
forge_query.use_ssl = true
forge_res = forge_query.request_head(forge_uri.path)
puts "Forge: #{forge_res.code}"
