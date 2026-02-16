# frozen_string_literal: true

module Talc
  module Proxy
    # Caddy reverse proxy provider using Caddyfile configuration
    # Fallback for when Caddy API is not available
    class CaddyFile < Base
      BINARY_PATH = '/usr/bin/caddy'
      SERVICE_NAME = 'caddy'
      CONFIG_DIR = '/etc/caddy/conf.d'
      CONFIG_FILE = File.join(CONFIG_DIR, 'talc')

      def initialize
        @config_file = CONFIG_FILE
      end

      # Add a route by updating the Caddyfile
      def add_route(domain, port, ip: '127.0.0.1')
        raise ProxyError, "Caddy is not installed" unless installed?

        ensure_config_dir

        routes = load_routes
        routes[domain] = { port: port, ip: ip }
        save_routes(routes)
        reload
      end

      # Remove a route from the Caddyfile
      def remove_route(domain)
        raise ProxyError, "Caddy is not installed" unless installed?

        routes = load_routes

        unless routes.key?(domain)
          raise DomainNotFoundError, "Route for domain '#{domain}' not found"
        end

        routes.delete(domain)
        save_routes(routes)
        reload
      end

      # List all routes from the Caddyfile
      def list_routes
        routes = load_routes
        routes.map do |domain, config|
          {
            domain: domain,
            port: config[:port],
            ip: config[:ip]
          }
        end
      end

      # Reload Caddy service
      def reload
        raise ProxyError, "Caddy is not installed" unless installed?

        begin
          if System.service_running?(SERVICE_NAME)
            System.reload_service(SERVICE_NAME)
          else
            System.start_service(SERVICE_NAME)
          end
        rescue => e
          raise ServiceError, "Failed to reload Caddy: #{e.message}"
        end
      end

      # Check if Caddy is installed
      def installed?
        System.binary_exists?(BINARY_PATH)
      end

      # Get Caddy service status
      def status
        {
          running: System.service_running?(SERVICE_NAME),
          enabled: System.service_enabled?(SERVICE_NAME),
          installed: installed?
        }
      end

      # Remove talc configuration
      def teardown
        if File.exist?(@config_file)
          System.delete_file_sudo(@config_file)
          reload if System.service_running?(SERVICE_NAME)
        end
      end

      private

      def ensure_config_dir
        unless Dir.exist?(CONFIG_DIR)
          begin
            System.sudo_exec("mkdir -p #{CONFIG_DIR}")
          rescue => e
            raise ProxyError, "Failed to create config directory: #{e.message}"
          end
        end
      end

      def load_routes
        return {} unless File.exist?(@config_file)

        content = System.read_file(@config_file)
        parse_caddyfile(content)
      rescue => e
        raise ProxyError, "Failed to load Caddyfile: #{e.message}"
      end

      def save_routes(routes)
        content = generate_caddyfile(routes)

        begin
          System.write_file_sudo(@config_file, content)
        rescue => e
          raise ProxyError, "Failed to save Caddyfile: #{e.message}"
        end
      end

      def parse_caddyfile(content)
        routes = {}
        current_domain = nil

        content.each_line do |line|
          line = line.strip

          # Match domain line (e.g., "myapp.internal {")
          if line =~ /^([\w\-.]+)\s*\{/
            current_domain = $1
          # Match reverse_proxy line
          elsif line =~ /reverse_proxy\s+(.+):(\d+)/
            ip = $1
            port = $2.to_i
            routes[current_domain] = { port: port, ip: ip } if current_domain
          # Reset on closing brace
          elsif line == '}'
            current_domain = nil
          end
        end

        routes
      end

      def generate_caddyfile(routes)
        return "# Managed by Talc\n" if routes.empty?

        content = +"# Managed by Talc\n\n"

        routes.each do |domain, config|
          content << "#{domain} {\n"
          content << "  reverse_proxy #{config[:ip]}:#{config[:port]}\n"
          content << "}\n\n"
        end

        content
      end
    end
  end
end
