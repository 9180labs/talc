# frozen_string_literal: true

require_relative "talc/version"
require_relative "talc/errors"
require_relative "talc/config"
require_relative "talc/storage"
require_relative "talc/network"
require_relative "talc/system"
require_relative "talc/certificate_manager"
require_relative "talc/dns/base"
require_relative "talc/dns/dnsmasq"
require_relative "talc/proxy/base"
require_relative "talc/proxy/caddy_api"
require_relative "talc/proxy/caddy_file"
require_relative "talc/domain_manager"
require_relative "talc/cli"

module Talc
end
