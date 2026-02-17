# frozen_string_literal: true

module Talc
  # Core business logic for managing domains
  # Orchestrates DNS, proxy, and storage operations with transaction support
  class DomainManager
    attr_reader :config, :storage, :dns_provider, :proxy_provider, :certificate_manager

    def initialize(config: nil, storage: nil, dns_provider: nil, proxy_provider: nil, certificate_manager: nil)
      @config = config || Config.new
      @storage = storage || Storage.new
      @dns_provider = dns_provider || create_dns_provider
      @proxy_provider = proxy_provider || create_proxy_provider
      @certificate_manager = certificate_manager || CertificateManager.new(certs_dir: @config.certs_dir)
      @dns_configured = false
    end

    # Add a new domain
    # @param name [String] The domain name (without suffix)
    # @param port [Integer] The port to proxy to
    # @param ip [String] The IP to proxy to (default: '127.0.0.1')
    # @return [Hash] The created domain
    def add(name, port, ip: '127.0.0.1')
      validate_domain_name!(name)
      validate_port!(port)

      full_domain = "#{name}.#{@config.domain_suffix}"

      # Check if domain already exists
      if @storage.find(name)
        raise DomainExistsError, "Domain '#{name}' already exists"
      end

      # Ensure DNS is configured (one-time setup)
      ensure_dns_configured!

      # Generate wildcard TLS cert only when using Caddy API; Caddyfile provider uses on-demand TLS
      cert_path = nil
      key_path = nil
      if @config.enable_tls && !@proxy_provider.is_a?(Proxy::CaddyFile)
        paths = @certificate_manager.generate_for_domain(full_domain)
        cert_path = paths[:cert_path]
        key_path = paths[:key_path]
      end

      # Add proxy route (with optional TLS cert paths)
      begin
        @proxy_provider.add_route(full_domain, port, ip: ip, cert_path: cert_path, key_path: key_path)
      rescue => e
        @certificate_manager.remove(full_domain) if cert_path
        raise ProxyError, "Failed to add proxy route: #{e.message}"
      end

      # Save to storage
      begin
        domain = @storage.add(name, port, ip: ip)
      rescue => e
        # Rollback: remove proxy route and cert
        begin
          @proxy_provider.remove_route(full_domain)
        rescue
          # Best effort rollback
        end
        @certificate_manager.remove(full_domain) if cert_path
        raise StorageError, "Failed to save domain: #{e.message}"
      end

      domain
    end

    # Remove a domain
    # @param name [String] The domain name
    # @return [Hash] The removed domain
    def remove(name)
      domain = @storage.find(name)
      raise DomainNotFoundError, "Domain '#{name}' not found" unless domain

      full_domain = "#{name}.#{@config.domain_suffix}"

      # Remove proxy route
      begin
        @proxy_provider.remove_route(full_domain)
      rescue => e
        # Log but continue - maybe route was already removed
        warn "Warning: Failed to remove proxy route: #{e.message}"
      end

      # Remove TLS cert files if we generated them (Caddy API); Caddyfile uses on-demand
      @certificate_manager.remove(full_domain) if @config.enable_tls && !@proxy_provider.is_a?(Proxy::CaddyFile)

      # Remove from storage
      @storage.remove(name)
    end

    # List all domains
    # @param format [String] Output format: 'table' or 'json'
    # @return [Array<Hash>] Array of domains
    def list(format: 'table')
      domains = @storage.all

      # Add full domain name to each entry
      domains.map do |domain|
        domain.merge('full_domain' => "#{domain['name']}.#{@config.domain_suffix}")
      end
    end

    # Update a domain
    # @param name [String] The domain name
    # @param port [Integer, nil] New port (if provided)
    # @param ip [String, nil] New IP (if provided)
    # @return [Hash] The updated domain
    def update(name, port: nil, ip: nil)
      domain = @storage.find(name)
      raise DomainNotFoundError, "Domain '#{name}' not found" unless domain

      validate_port!(port) if port

      full_domain = "#{name}.#{@config.domain_suffix}"
      new_port = port || domain['port']
      new_ip = ip || domain['ip']

      # Cert paths for re-add when using Caddy API with TLS (reuse existing cert)
      cert_path = nil
      key_path = nil
      if @config.enable_tls && !@proxy_provider.is_a?(Proxy::CaddyFile) && @certificate_manager.exists?(full_domain)
        cert_path = @certificate_manager.path_for_cert(full_domain)
        key_path = @certificate_manager.path_for_key(full_domain)
      end

      # Update proxy route (remove and re-add)
      begin
        @proxy_provider.remove_route(full_domain)
        @proxy_provider.add_route(full_domain, new_port, ip: new_ip, cert_path: cert_path, key_path: key_path)
      rescue => e
        # Try to restore old route
        use_certs = @config.enable_tls && !@proxy_provider.is_a?(Proxy::CaddyFile) && @certificate_manager.exists?(full_domain)
        old_cert_path = use_certs ? @certificate_manager.path_for_cert(full_domain) : nil
        old_key_path = use_certs ? @certificate_manager.path_for_key(full_domain) : nil
        begin
          @proxy_provider.add_route(full_domain, domain['port'], ip: domain['ip'], cert_path: old_cert_path, key_path: old_key_path)
        rescue
          # Best effort restoration
        end
        raise ProxyError, "Failed to update proxy route: #{e.message}"
      end

      # Update storage
      begin
        @storage.update(name, port: port, ip: ip)
      rescue => e
        # Try to restore old route
        use_certs = @config.enable_tls && !@proxy_provider.is_a?(Proxy::CaddyFile) && @certificate_manager.exists?(full_domain)
        old_cert_path = use_certs ? @certificate_manager.path_for_cert(full_domain) : nil
        old_key_path = use_certs ? @certificate_manager.path_for_key(full_domain) : nil
        begin
          @proxy_provider.remove_route(full_domain)
          @proxy_provider.add_route(full_domain, domain['port'], ip: domain['ip'], cert_path: old_cert_path, key_path: old_key_path)
        rescue
          # Best effort restoration
        end
        raise StorageError, "Failed to update domain: #{e.message}"
      end
    end

    # Get status of DNS and proxy services
    # @return [Hash] Status information
    def status
      {
        dns: @dns_provider.status,
        proxy: @proxy_provider.status,
        local_ip: detect_local_ip,
        domain_suffix: @config.domain_suffix,
        domains_count: @storage.all.size
      }
    end

    # Teardown all Talc configuration
    def teardown
      # Remove all domains
      domains = @storage.all
      domains.each do |domain|
        full_domain = "#{domain['name']}.#{@config.domain_suffix}"
        begin
          @proxy_provider.remove_route(full_domain)
        rescue
          # Best effort
        end
      end

      # Clear storage
      @storage.clear

      # Remove DNS configuration
      if @dns_provider.respond_to?(:teardown)
        @dns_provider.teardown
      end

      # Remove proxy configuration
      if @proxy_provider.respond_to?(:teardown)
        @proxy_provider.teardown
      end
    end

    private

    def create_dns_provider
      case @config.dns_provider
      when 'dnsmasq'
        DNS::Dnsmasq.new
      else
        raise ConfigError, "Unknown DNS provider: #{@config.dns_provider}"
      end
    end

    def create_proxy_provider
      # Try Caddy API first, fallback to file-based
      api_provider = Proxy::CaddyAPI.new(api_url: @config.caddy_api_url)

      if api_provider.installed? && api_provider.api_reachable?
        api_provider
      else
        Proxy::CaddyFile.new
      end
    end

    def ensure_dns_configured!
      return if @dns_configured

      unless @dns_provider.installed?
        raise DNSError, "DNS provider '#{@config.dns_provider}' is not installed"
      end

      # Check if DNS is already configured (config file exists)
      if @dns_provider.status[:dnsmasq][:configured]
        # DNS already configured (by talc setup), just ensure it's running
        @dns_provider.reload unless @dns_provider.status[:dnsmasq][:running]
        @dns_configured = true
      else
        # First time setup - configure DNS
        local_ip = detect_local_ip
        @dns_provider.configure(local_ip, @config.domain_suffix)
        @dns_provider.reload
        @dns_configured = true
      end
    end

    def detect_local_ip
      @config.local_ip || Network.detect_local_ip
    end

    def validate_domain_name!(name)
      if name.nil? || name.empty?
        raise ArgumentError, "Domain name cannot be empty"
      end

      unless name =~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/i
        raise ArgumentError, "Invalid domain name: #{name}. Use only alphanumeric characters and hyphens."
      end

      if name.include?('.')
        raise ArgumentError, "Domain name should not include dots. Use only the subdomain part."
      end
    end

    def validate_port!(port)
      unless port.is_a?(Integer) && port > 0 && port <= 65535
        raise ArgumentError, "Invalid port: #{port}. Port must be between 1 and 65535."
      end
    end
  end
end
