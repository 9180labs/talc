# frozen_string_literal: true

module Talc
  module Proxy
    # Caddy reverse proxy provider by modifying the main Caddyfile.
    # Fallback when Caddy API is not available. Reads/writes a marked section
    # in /etc/caddy/Caddyfile so the rest of the file is preserved.
    class CaddyFile < Base
      BINARY_PATH = '/usr/bin/caddy'
      SERVICE_NAME = 'caddy'
      CONFIG_FILE = '/etc/caddy/Caddyfile'
      START_MARKER = '# --- Managed by Talc ---'
      END_MARKER = '# --- End Talc ---'

      def initialize
        @config_file = CONFIG_FILE
      end

      # Add a route by updating the Talc section in the main Caddyfile
      def add_route(domain, port, ip: '127.0.0.1', cert_path: nil, key_path: nil)
        raise ProxyError, "Caddy is not installed" unless installed?

        ensure_config_dir

        routes = load_routes
        routes[domain] = { port: port, ip: ip, cert_path: cert_path, key_path: key_path }
        save_routes(routes)
        reload_or_warn
      end

      # Remove a route from the Talc section
      def remove_route(domain)
        raise ProxyError, "Caddy is not installed" unless installed?

        routes = load_routes

        unless routes.key?(domain)
          raise DomainNotFoundError, "Route for domain '#{domain}' not found"
        end

        routes.delete(domain)
        save_routes(routes)
        reload_or_warn
      end

      # List all routes from the Talc section
      def list_routes
        routes = load_routes
        routes.map do |domain, config|
          {
            domain: domain,
            port: config[:port],
            ip: config[:ip],
            cert_path: config[:cert_path],
            key_path: config[:key_path]
          }
        end
      end

      # Reload Caddy service (validates main Caddyfile before reloading)
      def reload
        raise ProxyError, "Caddy is not installed" unless installed?

        validate_config!
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

      # Reload Caddy; on failure warn and continue so add/remove still succeed
      def reload_or_warn
        reload
      rescue ServiceError, ProxyError => e
        warn "Caddy reload failed: #{e.message}. Run 'sudo systemctl reload caddy' or 'sudo systemctl restart caddy' after fixing Caddy config."
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

      # Remove Talc section from the main Caddyfile (rest of file unchanged)
      def teardown
        full = read_full_caddyfile
        return if full.nil? || full.empty?

        new_content = strip_talc_section(full)
        new_content = new_content.strip.empty? ? "# Caddyfile\n" : new_content.strip + "\n"
        System.write_file_sudo(@config_file, new_content)

        if System.service_running?(SERVICE_NAME)
          begin
            System.reload_service(SERVICE_NAME)
          rescue
            # Best effort
          end
        end
      end

      private

      def validate_config!
        return unless File.exist?(@config_file)

        System.sudo_exec("#{BINARY_PATH} validate --config #{@config_file} --adapter caddyfile")
      rescue PermissionError => e
        raise ProxyError, "Caddy config invalid or validation failed: #{e.message}"
      end

      def ensure_config_dir
        dir = File.dirname(@config_file)
        return if Dir.exist?(dir)

        begin
          System.sudo_exec("mkdir -p #{dir}")
        rescue => e
          raise ProxyError, "Failed to create config directory: #{e.message}"
        end
      end

      def read_full_caddyfile
        return nil unless File.exist?(@config_file)

        System.read_file(@config_file)
      rescue => e
        raise ProxyError, "Failed to read Caddyfile: #{e.message}"
      end

      def extract_talc_section(full_content)
        return nil unless full_content.include?(START_MARKER) && full_content.include?(END_MARKER)

        start_idx = full_content.index(START_MARKER)
        end_idx = full_content.index(END_MARKER)
        return nil if start_idx.nil? || end_idx.nil? || end_idx <= start_idx

        full_content[(start_idx + START_MARKER.length)..(end_idx - 1)].strip
      end

      def strip_talc_section(full_content)
        return full_content unless full_content.include?(START_MARKER) && full_content.include?(END_MARKER)

        start_idx = full_content.index(START_MARKER)
        end_idx = full_content.index(END_MARKER)
        return full_content if start_idx.nil? || end_idx.nil?

        before = start_idx.zero? ? '' : full_content[0..start_idx - 1].strip
        after = full_content[end_idx + END_MARKER.length..].strip
        [before, after].reject(&:empty?).join("\n\n")
      end

      # Find the first top-level global block { ... } at the start of content (after comments/blank lines).
      # Returns [content_before, global_block, content_after] or [content, nil, ''] if none.
      def split_global_block(content)
        lines = content.lines
        start_idx = nil
        lines.each_with_index do |line, i|
          stripped = line.strip
          next if stripped.empty?
          next if stripped.start_with?('#')
          if stripped == '{' || stripped.start_with?('{')
            start_idx = i
            break
          end
          # Not a global block start; no global block at top
          return [content, nil, '']
        end
        return [content, nil, ''] if start_idx.nil?

        depth = 0
        end_idx = nil
        lines[start_idx..].each_with_index do |line, j|
          depth += line.count('{') - line.count('}')
          if depth == 0
            end_idx = start_idx + j
            break
          end
        end
        return [content, nil, ''] if end_idx.nil?

        before = start_idx.zero? ? '' : lines[0...start_idx].join.strip
        global = lines[start_idx..end_idx].join
        after = lines[(end_idx + 1)..].join.strip
        [before, global, after]
      end

      # Inserted into existing global block (outer 2-space indent added in merge)
      ON_DEMAND_TLS_INSERT = <<~BLOCK.strip
        on_demand_tls {
            ask http://127.0.0.1/talc-ask
        }
      BLOCK

      def merge_on_demand_tls_into_global(global_block)
        return global_block if global_block.include?('on_demand_tls')
        # Insert before the closing "}" so it stays inside the global block
        global_block.sub(/\n(\s*\}\s*)\z/m, "\n  #{ON_DEMAND_TLS_INSERT}\n\\1")
      end

      def load_routes
        full = read_full_caddyfile
        return {} if full.nil? || full.empty?

        section = extract_talc_section(full)
        return {} if section.nil? || section.empty?

        parse_caddyfile(section)
      rescue => e
        raise ProxyError, "Failed to load Caddyfile: #{e.message}"
      end

      def parse_caddyfile(content)
        routes = {}
        current_domain = nil

        content.each_line do |line|
          line = line.strip

          if line =~ /^([\w\-.]+)(?:,\s*\*\.\1)?\s*\{/
            current_domain = $1
          elsif line =~ /reverse_proxy\s+(.+):(\d+)/
            ip = $1
            port = $2.to_i
            if current_domain
              routes[current_domain] = { port: port, ip: ip, cert_path: nil, key_path: nil }
            end
          elsif line == '}'
            current_domain = nil
          end
        end

        routes
      end

      def save_routes(routes)
        full = read_full_caddyfile
        full = '' if full.nil?

        rest = full.include?(START_MARKER) && full.include?(END_MARKER) ? strip_talc_section(full) : full.strip
        before_global, global_block, after_global = split_global_block(rest)

        if global_block
          merged_global = merge_on_demand_tls_into_global(global_block)
          section_content = generate_talc_section(routes, include_global: false)
          talc_section = "#{START_MARKER}\n#{section_content}\n#{END_MARKER}"
          parts = [before_global.strip, merged_global, talc_section, after_global].reject(&:empty?)
          new_full = parts.join("\n\n")
        else
          section_content = generate_talc_section(routes, include_global: true)
          new_section = "#{START_MARKER}\n#{section_content}\n#{END_MARKER}"
          new_full = rest.strip.empty? ? new_section : "#{new_section}\n\n#{rest.strip}"
        end

        System.write_file_sudo(@config_file, new_full + "\n")
      rescue => e
        raise ProxyError, "Failed to save Caddyfile: #{e.message}"
      end

      def generate_talc_section(routes, include_global: true)
        content = +""
        content << "{\n  on_demand_tls {\n    ask http://127.0.0.1/talc-ask\n  }\n}\n\n" if include_global
        content << ":80 {\n  handle /talc-ask {\n    respond 200\n  }\n}\n\n"

        routes.each do |domain, config|
          content << "#{domain}, *.#{domain} {\n"
          content << "  tls {\n    on_demand\n  }\n"
          content << "  reverse_proxy #{config[:ip]}:#{config[:port]}\n"
          content << "}\n\n"
        end

        content.strip
      end
    end
  end
end
