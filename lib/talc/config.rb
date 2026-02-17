# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module Talc
  # Configuration management for Talc
  # Loads settings from ~/.config/talc/config.yml with sensible defaults
  class Config
    DEFAULT_CONFIG_PATH = File.join(Dir.home, '.config', 'talc', 'config.yml')
    DEFAULT_DOMAIN_SUFFIX = 'internal'
    DEFAULT_CADDY_API_URL = 'http://localhost:2019'
    DEFAULT_CERTS_DIR = '/etc/caddy/certs'

    attr_reader :domain_suffix, :local_ip, :dns_provider, :caddy_api_url, :config_path,
                :enable_tls, :certs_dir

    def initialize(config_path: DEFAULT_CONFIG_PATH)
      @config_path = config_path
      load_config
    end

    # Create default configuration file
    def self.create_default(path: DEFAULT_CONFIG_PATH)
      FileUtils.mkdir_p(File.dirname(path))

      default_config = {
        'domain_suffix' => DEFAULT_DOMAIN_SUFFIX,
        'local_ip' => 'auto',
        'dns_provider' => 'dnsmasq',
        'caddy_api_url' => DEFAULT_CADDY_API_URL,
        'enable_tls' => true,
        'certs_dir' => DEFAULT_CERTS_DIR
      }

      File.write(path, YAML.dump(default_config))
      path
    end

    private

    def load_config
      if File.exist?(@config_path)
        config_data = YAML.load_file(@config_path)
        validate_config!(config_data)
        apply_config(config_data)
      else
        apply_defaults
      end
    rescue Psych::SyntaxError => e
      raise ConfigError, "Invalid YAML in config file: #{e.message}"
    rescue => e
      raise ConfigError, "Failed to load config: #{e.message}"
    end

    def validate_config!(config)
      raise ConfigError, "Config must be a Hash" unless config.is_a?(Hash)

      if config['domain_suffix'] && !valid_domain_suffix?(config['domain_suffix'])
        raise ConfigError, "Invalid domain_suffix: #{config['domain_suffix']}"
      end

      if config['dns_provider'] && !%w[dnsmasq].include?(config['dns_provider'])
        raise ConfigError, "Unsupported dns_provider: #{config['dns_provider']}"
      end
    end

    def valid_domain_suffix?(suffix)
      suffix =~ /^[a-z0-9]+$/i
    end

    def apply_config(config)
      @domain_suffix = config['domain_suffix'] || DEFAULT_DOMAIN_SUFFIX
      @local_ip = config['local_ip'] == 'auto' ? nil : config['local_ip']
      @dns_provider = config['dns_provider'] || 'dnsmasq'
      @caddy_api_url = config['caddy_api_url'] || DEFAULT_CADDY_API_URL
      @enable_tls = config.key?('enable_tls') ? config['enable_tls'] : true
      @certs_dir = config['certs_dir'] || DEFAULT_CERTS_DIR
    end

    def apply_defaults
      @domain_suffix = DEFAULT_DOMAIN_SUFFIX
      @local_ip = nil
      @dns_provider = 'dnsmasq'
      @caddy_api_url = DEFAULT_CADDY_API_URL
      @enable_tls = true
      @certs_dir = DEFAULT_CERTS_DIR
    end
  end
end
