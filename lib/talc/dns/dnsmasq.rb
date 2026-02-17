# frozen_string_literal: true

module Talc
  module DNS
    # Dnsmasq DNS provider implementation
    # Architecture: systemd-resolved (port 53) → dnsmasq (port 5335)
    # systemd-resolved forwards .internal domains to dnsmasq on localhost:5335
    #
    # Configuration Issue & Solution:
    # Problem: dnsmasq wasn't loading config files from /etc/dnsmasq.d/ even though
    #          they existed. This caused wildcard domain resolution to fail.
    # Root Cause: The conf-dir directive in /etc/dnsmasq.conf was commented out by default.
    # Solution: Automatically enable conf-dir=/etc/dnsmasq.d/,*.conf in /etc/dnsmasq.conf
    #           during setup (see enable_dnsmasq_conf_dir method).
    class Dnsmasq < Base
      CONFIG_PATH = '/etc/dnsmasq.d/talc.conf'
      BINARY_PATH = '/usr/bin/dnsmasq'
      SERVICE_NAME = 'dnsmasq'
      SYSTEMD_RESOLVED_SERVICE_NAME = 'systemd-resolved'
      SYSTEMD_RESOLVED_CONFIG_PATH = '/etc/systemd/resolved.conf.d/talc.conf'
      DNSMASQ_CONF_PATH = '/etc/dnsmasq.conf'
      DNSMASQ_PORT = 5335

      def initialize
        @config_path = CONFIG_PATH
      end

      # Configure dnsmasq with wildcard DNS rule and systemd-resolved forwarding
      def configure(local_ip, domain_suffix)
        preflight_checks

        begin
          # Enable conf-dir in main dnsmasq.conf if needed (FIX for config loading issue)
          enable_dnsmasq_conf_dir

          # Write dnsmasq config for port 5335
          System.write_file_sudo(@config_path, generate_dnsmasq_config(local_ip, domain_suffix))

          # Configure systemd-resolved to forward .internal to dnsmasq
          System.write_file_sudo(SYSTEMD_RESOLVED_CONFIG_PATH, generate_systemd_resolved_config(domain_suffix))

          # Reload systemd daemon
          System.sudo_exec("systemctl daemon-reload")

          # Restart systemd-resolved to apply new config
          System.restart_service(SYSTEMD_RESOLVED_SERVICE_NAME)
        rescue => e
          # Rollback on any failure
          rollback_configuration
          raise DNSError, "Configuration failed: #{e.message}\nSystem state has been restored."
        end
      end

      # Reload dnsmasq service
      def reload
        raise DNSError, "dnsmasq is not installed" unless installed?

        begin
          if System.service_running?(SERVICE_NAME)
            System.restart_service(SERVICE_NAME)
          else
            System.start_service(SERVICE_NAME)
          end
        rescue => e
          raise ServiceError, "Failed to reload dnsmasq: #{e.message}"
        end
      end

      # Get dnsmasq service status
      def status
        {
          dnsmasq: {
            running: System.service_running?(SERVICE_NAME),
            enabled: System.service_enabled?(SERVICE_NAME),
            installed: installed?,
            configured: File.exist?(@config_path),
            port: listening_on_port?(DNSMASQ_PORT)
          },
          systemd_resolved: {
            running: System.service_running?(SYSTEMD_RESOLVED_SERVICE_NAME),
            enabled: System.service_enabled?(SYSTEMD_RESOLVED_SERVICE_NAME),
            configured: File.exist?(SYSTEMD_RESOLVED_CONFIG_PATH)
          }
        }
      end

      # Check if dnsmasq is installed
      def installed?
        System.binary_exists?(BINARY_PATH)
      end

      # Remove talc configuration
      def teardown
        errors = []

        # Remove dnsmasq config
        begin
          if File.exist?(@config_path)
            System.delete_file_sudo(@config_path)
          end
        rescue => e
          errors << "Failed to remove dnsmasq config: #{e.message}"
        end

        # Remove systemd-resolved config
        begin
          if File.exist?(SYSTEMD_RESOLVED_CONFIG_PATH)
            System.delete_file_sudo(SYSTEMD_RESOLVED_CONFIG_PATH)
          end
        rescue => e
          errors << "Failed to remove systemd-resolved config: #{e.message}"
        end

        # Stop and disable dnsmasq (it was started by Talc; without our config
        # it reverts to port 53 which conflicts with systemd-resolved)
        begin
          System.stop_service(SERVICE_NAME) if System.service_running?(SERVICE_NAME)
          System.disable_service(SERVICE_NAME) if System.service_enabled?(SERVICE_NAME)
        rescue => e
          errors << "Failed to stop dnsmasq: #{e.message}"
        end

        # Restart systemd-resolved to remove .internal forwarding
        begin
          System.sudo_exec("systemctl daemon-reload")
          System.restart_service(SYSTEMD_RESOLVED_SERVICE_NAME) if System.service_running?(SYSTEMD_RESOLVED_SERVICE_NAME)
        rescue => e
          errors << "Failed to restart systemd-resolved: #{e.message}"
        end

        # Report errors if any occurred
        raise DNSError, errors.join("; ") unless errors.empty?
      end

      private

      def generate_dnsmasq_config(local_ip, domain_suffix)
        <<~CONFIG
          # Managed by Talc
          # Architecture: systemd-resolved (port 53) forwards .#{domain_suffix} → dnsmasq (port #{DNSMASQ_PORT})
          port=#{DNSMASQ_PORT}
          listen-address=127.0.0.1
          bind-interfaces

          # Don't read /etc/resolv.conf (systemd-resolved handles forwarding)
          no-resolv

          # We only handle .#{domain_suffix} queries (no upstream needed)
          # All other queries are handled by systemd-resolved

          # Wildcard DNS resolution for *.#{domain_suffix} domains
          address=/.#{domain_suffix}/#{local_ip}
        CONFIG
      end

      def generate_systemd_resolved_config(domain_suffix)
        <<~CONFIG
          # Managed by Talc
          # Forward all .#{domain_suffix} DNS queries to dnsmasq on localhost:#{DNSMASQ_PORT}
          [Resolve]
          DNS=127.0.0.1:#{DNSMASQ_PORT}
          Domains=~#{domain_suffix}
        CONFIG
      end

      # Verify dnsmasq is listening on specified port on localhost
      def listening_on_port?(port)
        stdout, _stderr, status = System.exec_command("ss -tulpn 2>/dev/null | grep ':#{port}.*dnsmasq'")
        return false unless status.success? && !stdout.empty?

        # Check if dnsmasq is bound to localhost (127.0.0.1)
        stdout.lines.any? do |line|
          line.include?('dnsmasq') && line.match?(/127\.0\.0\.1:#{port}\s/)
        end
      end

      # Validate sudo, dnsmasq installed, systemd-resolved running
      def preflight_checks
        raise DNSError, "sudo is not available" unless System.sudo_available?
        raise DNSError, "dnsmasq is not installed" unless installed?

        unless System.service_running?(SYSTEMD_RESOLVED_SERVICE_NAME)
          raise DNSError, "systemd-resolved is not running. Please start it with: sudo systemctl start systemd-resolved"
        end

        # Check if port 5335 is available (or only used by dnsmasq)
        check_dnsmasq_port_availability
      end

      # Check if port 5335 is available or only used by our dnsmasq
      def check_dnsmasq_port_availability
        stdout, _stderr, _status = System.exec_command("ss -tulpn 2>/dev/null | grep ':#{DNSMASQ_PORT} '")

        return if stdout.empty? # Port is free

        # Only check for conflicts on 127.0.0.1 where dnsmasq actually binds.
        # Other processes (e.g. Spotify/Avahi mDNS) may use port 5335 on 0.0.0.0
        # or multicast addresses without conflicting.
        localhost_lines = stdout.lines.select do |line|
          line.match?(/127\.0\.0\.1:#{DNSMASQ_PORT}\s/)
        end

        return if localhost_lines.empty? # Nothing bound on 127.0.0.1, no conflict

        # If it's our dnsmasq, that's fine
        return if localhost_lines.all? { |line| line.include?('dnsmasq') }

        # Something else is bound to 127.0.0.1 on this port
        raise DNSError, "Port #{DNSMASQ_PORT} is in use on 127.0.0.1 by another process.\nPlease stop it before running setup."
      end

      # Rollback on configuration failure
      def rollback_configuration
        # Delete dnsmasq config if it was created
        System.delete_file_sudo(CONFIG_PATH) if File.exist?(CONFIG_PATH)

        # Delete systemd-resolved config if it was created
        System.delete_file_sudo(SYSTEMD_RESOLVED_CONFIG_PATH) if File.exist?(SYSTEMD_RESOLVED_CONFIG_PATH)

        # Restart systemd-resolved to revert to previous state
        begin
          System.sudo_exec("systemctl daemon-reload")
          System.restart_service(SYSTEMD_RESOLVED_SERVICE_NAME)
        rescue => e
          warn "Warning: Failed to restart systemd-resolved during rollback: #{e.message}"
        end
      end

      # Enable conf-dir in /etc/dnsmasq.conf to read /etc/dnsmasq.d/*.conf files
      # This is THE FIX for the configuration loading issue - dnsmasq won't load
      # configs from /etc/dnsmasq.d/ unless this directive is enabled.
      def enable_dnsmasq_conf_dir
        return unless File.exist?(DNSMASQ_CONF_PATH)

        content = System.read_file(DNSMASQ_CONF_PATH)

        # Check if conf-dir is already enabled
        return if content.match?(/^conf-dir=\/etc\/dnsmasq\.d/)

        # Check if conf-dir line exists but is commented
        if content.match?(/^#conf-dir=\/etc\/dnsmasq\.d/)
          # Uncomment the line
          updated_content = content.gsub(/^#(conf-dir=\/etc\/dnsmasq\.d)/, '\1')
          System.write_file_sudo(DNSMASQ_CONF_PATH, updated_content)
        else
          # Add conf-dir line at the end
          updated_content = content + "\n# Added by Talc - enables loading of /etc/dnsmasq.d/*.conf\nconf-dir=/etc/dnsmasq.d/,*.conf\n"
          System.write_file_sudo(DNSMASQ_CONF_PATH, updated_content)
        end
      end
    end
  end
end
