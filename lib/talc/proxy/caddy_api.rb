# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Talc
  module Proxy
    # Caddy reverse proxy provider using the JSON API
    # Manages routes via HTTP requests to the Caddy admin API
    class CaddyAPI < Base
      BINARY_PATH = '/usr/bin/caddy'
      SERVICE_NAME = 'caddy'
      DEFAULT_API_URL = 'http://localhost:2019'
      SERVER_NAME = 'talc'

      attr_reader :api_url

      def initialize(api_url: DEFAULT_API_URL)
        @api_url = api_url
        @uri = URI.parse(@api_url)
      end

      # Add a route via Caddy API
      def add_route(domain, port, ip: '127.0.0.1', cert_path: nil, key_path: nil)
        raise ProxyError, "Caddy is not installed" unless installed?

        ensure_server_exists

        route = build_route_config(domain, port, ip)

        begin
          # Add the route to the talc server
          path = "/config/apps/http/servers/#{SERVER_NAME}/routes"
          response = post_json(path, route)

          unless response.is_a?(Net::HTTPSuccess)
            raise ProxyError, "Failed to add route: #{response.code} #{response.message}"
          end

          # Load TLS certificate so Caddy serves HTTPS on :443 for this domain
          if cert_path && key_path
            load_certificate(cert_path, key_path)
          end
        rescue => e
          raise ProxyError, "Failed to add route via Caddy API: #{e.message}"
        end
      end

      # Remove a route via Caddy API
      def remove_route(domain)
        raise ProxyError, "Caddy is not installed" unless installed?

        begin
          # Find and remove the route
          routes = list_routes
          route_index = routes.find_index { |r| r[:domain] == domain }

          if route_index
            path = "/config/apps/http/servers/#{SERVER_NAME}/routes/#{route_index}"
            response = delete(path)

            unless response.is_a?(Net::HTTPSuccess)
              raise ProxyError, "Failed to remove route: #{response.code}"
            end
          else
            raise DomainNotFoundError, "Route for domain '#{domain}' not found"
          end
        rescue DomainNotFoundError
          raise
        rescue => e
          raise ProxyError, "Failed to remove route via Caddy API: #{e.message}"
        end
      end

      # List all routes from the talc server
      def list_routes
        begin
          path = "/config/apps/http/servers/#{SERVER_NAME}/routes"
          response = get(path)

          if response.is_a?(Net::HTTPSuccess)
            routes_data = JSON.parse(response.body)
            parse_routes(routes_data)
          elsif response.code == '404'
            # Server doesn't exist yet
            []
          else
            raise ProxyError, "Failed to list routes: #{response.code}"
          end
        rescue JSON::ParserError => e
          raise ProxyError, "Invalid JSON response from Caddy API: #{e.message}"
        rescue => e
          raise ProxyError, "Failed to list routes: #{e.message}"
        end
      end

      # Caddy API applies changes immediately, no reload needed
      def reload
        # No-op for API-based configuration
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
          installed: installed?,
          api_reachable: api_reachable?
        }
      end

      # Check if Caddy API is reachable
      def api_reachable?
        response = get('/config/')
        response.is_a?(Net::HTTPSuccess)
      rescue
        false
      end

      # Ensure the talc server exists in Caddy config (listen on 80 and 443 for TLS)
      def ensure_server_exists
        path = "/config/apps/http/servers/#{SERVER_NAME}"
        response = get(path)

        if response.code == '404'
          # Create the server; listen on :443 so Caddy can serve HTTPS with loaded certs
          server_config = {
            listen: [':80', ':443'],
            routes: []
          }
          response = post_json(path, server_config)

          unless response.is_a?(Net::HTTPSuccess)
            raise ProxyError, "Failed to create Caddy server: #{response.code}"
          end
        else
          # Server exists; ensure it listens on :443 for TLS
          ensure_listen_443(path, response.body)
        end
      end

      def ensure_listen_443(server_path, body)
        data = JSON.parse(body)
        listen = data['listen'] || data[:listen] || [':80']
        listen = listen.map(&:to_s)
        return if listen.include?(':443')

        listen << ':443' unless listen.include?(':443')
        response = patch_json(server_path + '/listen', listen)
        unless response.is_a?(Net::HTTPSuccess)
          raise ProxyError, "Failed to add :443 listener: #{response.code}"
        end
      end

      # Load a certificate and key into Caddy's TLS app (for HTTPS on this domain)
      def load_certificate(cert_path, key_path)
        path = '/config/apps/tls/certificates'
        payload = {
          'load_files' => [
            { 'certificate' => cert_path, 'key' => key_path }
          ]
        }
        response = post_json(path, payload)
        unless response.is_a?(Net::HTTPSuccess)
          raise ProxyError, "Failed to load TLS certificate: #{response.code} #{response.body}"
        end
      end

      private

      def build_route_config(domain, port, ip)
        {
          match: [{
            host: [domain, "*.#{domain}"]
          }],
          handle: [{
            handler: 'reverse_proxy',
            upstreams: [{
              dial: "#{ip}:#{port}"
            }]
          }]
        }
      end

      def generate_route_id(domain)
        "talc_#{domain.gsub('.', '_')}"
      end

      def parse_routes(routes_data)
        return [] unless routes_data.is_a?(Array)

        routes_data.map do |route|
          next unless route['match']&.first&.dig('host')

          domain = route['match'].first['host'].first
          upstream = route.dig('handle', 0, 'upstreams', 0, 'dial')

          if upstream && upstream.include?(':')
            ip, port = upstream.split(':')
            {
              domain: domain,
              port: port.to_i,
              ip: ip
            }
          end
        end.compact
      end

      def get(path)
        uri = URI.join(@api_url, path)
        Net::HTTP.get_response(uri)
      end

      def post_json(path, data)
        uri = URI.join(@api_url, path)
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Post.new(uri.path, { 'Content-Type' => 'application/json' })
        request.body = JSON.generate(data)
        http.request(request)
      end

      def delete(path)
        uri = URI.join(@api_url, path)
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Delete.new(uri.path)
        http.request(request)
      end

      def patch_json(path, data)
        uri = URI.join(@api_url, path)
        http = Net::HTTP.new(uri.host, uri.port)
        request = Net::HTTP::Patch.new(uri.path)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(data)
        http.request(request)
      end
    end
  end
end
