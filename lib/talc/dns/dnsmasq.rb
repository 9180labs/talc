# frozen_string_literal: true

module Talc
  module DNS
    # Dnsmasq DNS provider implementation
    # Manages /etc/dnsmasq.d/talc.conf for wildcard domain resolution
    class Dnsmasq < Base
      CONFIG_PATH = '/etc/dnsmasq.d/talc.conf'
      BINARY_PATH = '/usr/bin/dnsmasq'
      SERVICE_NAME = 'dnsmasq'
      SYSTEMD_RESOLVED_SERVICE_NAME = 'systemd-resolved'
      RESOLV_CONF_PATH = '/etc/resolv.conf'
      DNSMASQ_CONF_PATH = '/etc/dnsmasq.conf'
      DNS_BACKUP_PATH = File.join(Dir.home, '.config', 'talc', 'dns_backup.json')
      # Legacy paths for detecting old architecture
      OLD_SYSTEMD_RESOLVED_CONFIG_PATH = '/etc/systemd/resolved.conf.d/talc.conf'
      OLD_SYSTEMD_OVERRIDE_PATH = '/etc/systemd/system/dnsmasq.service.d/talc.conf'

      def initialize
        @config_path = CONFIG_PATH
      end

      # Configure dnsmasq with wildcard DNS rule
      def configure(local_ip, domain_suffix)
        preflight_checks

        # Clean up old architecture if detected
        cleanup_old_architecture if old_architecture_detected?

        # Backup current DNS state
        backup_dns_state

        begin
          # Disable systemd-resolved
          disable_systemd_resolved

          # Wait for port 53 to be released
          unless wait_for_port_53_release
            port_info = check_port_53_status
            raise DNSError, "Port 53 is still in use after stopping systemd-resolved: #{port_info[:process]}"
          end

          # Enable conf-dir in main dnsmasq.conf if needed
          enable_dnsmasq_conf_dir

          # Write dnsmasq config for port 53
          System.write_file_sudo(@config_path, generate_dnsmasq_config(local_ip, domain_suffix))

          # Write /etc/resolv.conf to point to dnsmasq
          write_resolv_conf(generate_resolv_conf)

          # Reload systemd daemon to ensure clean state
          System.sudo_exec("systemctl daemon-reload")
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
        resolv_conf_content = nil
        if File.exist?(RESOLV_CONF_PATH)
          content = System.read_file(RESOLV_CONF_PATH)
          resolv_conf_content = content.lines.first(5).join
        end

        {
          dnsmasq: {
            running: System.service_running?(SERVICE_NAME),
            enabled: System.service_enabled?(SERVICE_NAME),
            installed: installed?,
            configured: File.exist?(@config_path),
            port: listening_on_port_53?
          },
          systemd_resolved: {
            running: System.service_running?(SYSTEMD_RESOLVED_SERVICE_NAME),
            masked: systemd_resolved_masked?
          },
          resolv_conf: {
            managed_by_talc: resolv_conf_managed_by_talc?,
            content: resolv_conf_content
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

        # Restore original DNS state from backup
        begin
          restore_dns_state
        rescue => e
          errors << "Failed to restore DNS state: #{e.message}"
        end

        # Remove dnsmasq config
        begin
          if File.exist?(@config_path)
            System.delete_file_sudo(@config_path)
          end
        rescue => e
          errors << "Failed to remove dnsmasq config: #{e.message}"
        end

        # Clean up old architecture files if they exist
        begin
          cleanup_old_architecture if old_architecture_detected?
        rescue => e
          errors << "Failed to clean up old architecture: #{e.message}"
        end

        # Restart dnsmasq to use default config
        begin
          if System.service_running?(SERVICE_NAME)
            System.restart_service(SERVICE_NAME)
          end
        rescue => e
          errors << "Failed to restart dnsmasq: #{e.message}"
        end

        # Report errors if any occurred
        raise DNSError, errors.join("; ") unless errors.empty?
      end

      private

      def generate_dnsmasq_config(local_ip, domain_suffix)
        <<~CONFIG
          # Managed by Talc
          port=53
          listen-address=127.0.0.1
          bind-interfaces

          # Don't read /etc/resolv.conf (we ARE the resolver)
          no-resolv

          # Upstream DNS for non-.#{domain_suffix} queries
          server=8.8.8.8
          server=8.8.4.4

          # Wildcard DNS resolution for *.#{domain_suffix} domains
          address=/.#{domain_suffix}/#{local_ip}
        CONFIG
      end

      def systemd_resolved_configured?
        File.exist?(OLD_SYSTEMD_RESOLVED_CONFIG_PATH)
      end

      # Backup current DNS configuration to JSON file
      def backup_dns_state
        require 'json'
        require 'fileutils'

        backup_dir = File.dirname(DNS_BACKUP_PATH)
        FileUtils.mkdir_p(backup_dir) unless Dir.exist?(backup_dir)

        # Check if resolv.conf is a symlink
        is_symlink = File.symlink?(RESOLV_CONF_PATH)
        symlink_target = is_symlink ? File.readlink(RESOLV_CONF_PATH) : nil
        content = is_symlink ? nil : File.read(RESOLV_CONF_PATH)

        # Get systemd-resolved state
        was_running = System.service_running?(SYSTEMD_RESOLVED_SERVICE_NAME)
        was_enabled = System.service_enabled?(SYSTEMD_RESOLVED_SERVICE_NAME)
        was_masked = System.service_masked?(SYSTEMD_RESOLVED_SERVICE_NAME)

        backup = {
          timestamp: Time.now.utc.iso8601,
          resolv_conf: {
            is_symlink: is_symlink,
            symlink_target: symlink_target,
            content: content
          },
          systemd_resolved: {
            was_running: was_running,
            was_enabled: was_enabled,
            was_masked: was_masked
          }
        }

        File.write(DNS_BACKUP_PATH, JSON.pretty_generate(backup))
      end

      # Restore original DNS configuration from backup
      def restore_dns_state
        return unless File.exist?(DNS_BACKUP_PATH)

        require 'json'
        backup = JSON.parse(File.read(DNS_BACKUP_PATH))

        # Restore resolv.conf
        resolv_conf = backup['resolv_conf']
        if resolv_conf['is_symlink']
          # Remove existing file/symlink
          System.sudo_exec("rm -f #{RESOLV_CONF_PATH}")
          # Recreate symlink
          System.sudo_exec("ln -sf #{resolv_conf['symlink_target']} #{RESOLV_CONF_PATH}")
        elsif resolv_conf['content']
          # Write static file
          write_resolv_conf(resolv_conf['content'])
        end

        # Restore systemd-resolved state
        systemd_state = backup['systemd_resolved']
        if systemd_state['was_running'] || systemd_state['was_enabled']
          enable_systemd_resolved unless systemd_state['was_masked']
        end

        # Delete backup file
        File.delete(DNS_BACKUP_PATH)
      rescue => e
        # Critical: backup restore failed
        critical_msg = <<~MSG
          CRITICAL: Failed to restore original DNS state.
          Backup location: #{DNS_BACKUP_PATH}
          Manual restore required.

          To restore manually:
          1. Check backup file: cat #{DNS_BACKUP_PATH}
          2. Restore resolv.conf: sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
          3. Unmask systemd-resolved: sudo systemctl unmask systemd-resolved
          4. Start systemd-resolved: sudo systemctl start systemd-resolved
        MSG
        raise DNSError, critical_msg
      end

      # Stop and mask systemd-resolved
      def disable_systemd_resolved
        if System.service_running?(SYSTEMD_RESOLVED_SERVICE_NAME)
          System.stop_service(SYSTEMD_RESOLVED_SERVICE_NAME)
        end
        System.mask_service(SYSTEMD_RESOLVED_SERVICE_NAME)
      end

      # Unmask and start systemd-resolved (for rollback)
      def enable_systemd_resolved
        System.unmask_service(SYSTEMD_RESOLVED_SERVICE_NAME)
        System.start_service(SYSTEMD_RESOLVED_SERVICE_NAME)
      end

      # Write /etc/resolv.conf, handling symlink case
      def write_resolv_conf(content)
        # Remove symlink if it exists
        if File.symlink?(RESOLV_CONF_PATH)
          System.sudo_exec("rm -f #{RESOLV_CONF_PATH}")
        end
        # Write static file
        System.write_file_sudo(RESOLV_CONF_PATH, content)
      end

      # Generate /etc/resolv.conf content
      def generate_resolv_conf
        <<~RESOLV
          # Managed by Talc
          nameserver 127.0.0.1
          # Fallback to Google DNS if dnsmasq is down
          nameserver 8.8.8.8
        RESOLV
      end

      # Check if service is masked
      def systemd_resolved_masked?
        System.service_masked?(SYSTEMD_RESOLVED_SERVICE_NAME)
      end

      # Verify dnsmasq is listening on port 53 on localhost
      def listening_on_port_53?
        stdout, _stderr, status = System.exec_command("ss -tulpn 2>/dev/null | grep ':53.*dnsmasq'")
        return false unless status.success? && !stdout.empty?

        # Check if dnsmasq is bound to localhost (127.0.0.1)
        stdout.lines.any? do |line|
          line.include?('dnsmasq') && line.match?(/127\.0\.0\.1:53\s/)
        end
      end

      # Check if resolv.conf has Talc header
      def resolv_conf_managed_by_talc?
        return false unless File.exist?(RESOLV_CONF_PATH)
        content = System.read_file(RESOLV_CONF_PATH)
        content.include?('Managed by Talc')
      end

      # Validate sudo, dnsmasq installed, port availability
      def preflight_checks
        raise DNSError, "sudo is not available" unless System.sudo_available?
        raise DNSError, "dnsmasq is not installed" unless installed?

        # Check what's using port 53
        port_info = check_port_53_status

        # If port is in use by something other than systemd-resolved, abort
        if port_info[:in_use] && !port_info[:used_by_systemd_resolved]
          raise DNSError, "Port 53 is in use by: #{port_info[:process]}\nPlease stop this service before running setup."
        end
      end

      # Check what's using port 53 on localhost
      def check_port_53_status
        # Only check for port 53 on localhost interfaces (127.0.0.1, ::1, 0.0.0.0, ::)
        # Ignore port 53 on other interfaces like Docker bridge (172.17.0.1)
        stdout, _stderr, _status = System.exec_command("ss -tulpn 2>/dev/null | grep ':53 '")

        if stdout.empty?
          { in_use: false, used_by_systemd_resolved: false, process: nil }
        else
          # Filter to only localhost bindings
          localhost_lines = stdout.lines.select do |line|
            # Match 127.0.0.1:53, [::1]:53, 0.0.0.0:53, or *:53 (which means all interfaces)
            line.match?(/127\.0\.0\.1:53\s/) ||
              line.match?(/\[::1\]:53\s/) ||
              line.match?(/0\.0\.0\.0:53\s/) ||
              line.match?(/\[::\]:53\s/) ||
              line.match?(/\*:53\s/)
          end

          if localhost_lines.empty?
            { in_use: false, used_by_systemd_resolved: false, process: nil }
          else
            used_by_resolved = localhost_lines.any? { |line| line.include?('systemd-resolve') }
            # Extract process info from first localhost binding
            process = localhost_lines.first&.strip || 'unknown'
            { in_use: true, used_by_systemd_resolved: used_by_resolved, process: process }
          end
        end
      end

      # Wait for port 53 to be released (with timeout)
      def wait_for_port_53_release(timeout_seconds: 5)
        require 'timeout'

        Timeout.timeout(timeout_seconds) do
          loop do
            port_info = check_port_53_status
            return true unless port_info[:in_use]
            sleep 0.2
          end
        end
        true
      rescue Timeout::Error
        false
      end

      # Check for old architecture config files
      def old_architecture_detected?
        File.exist?(OLD_SYSTEMD_RESOLVED_CONFIG_PATH) ||
          File.exist?(OLD_SYSTEMD_OVERRIDE_PATH)
      end

      # Remove old architecture config files
      def cleanup_old_architecture
        old_files = [
          OLD_SYSTEMD_RESOLVED_CONFIG_PATH,
          OLD_SYSTEMD_OVERRIDE_PATH
        ]

        old_files.each do |file|
          System.delete_file_sudo(file) if File.exist?(file)
        end

        System.sudo_exec("systemctl daemon-reload")
      end

      # Rollback on configuration failure
      def rollback_configuration
        # Delete dnsmasq config if it was created
        System.delete_file_sudo(CONFIG_PATH) if File.exist?(CONFIG_PATH)

        # Re-enable systemd-resolved
        begin
          enable_systemd_resolved
        rescue => e
          warn "Warning: Failed to re-enable systemd-resolved during rollback: #{e.message}"
        end

        # Restore original DNS state
        restore_dns_state
      end

      # Enable conf-dir in /etc/dnsmasq.conf to read /etc/dnsmasq.d/*.conf files
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
          updated_content = content + "\n# Added by Talc\nconf-dir=/etc/dnsmasq.d/,*.conf\n"
          System.write_file_sudo(DNSMASQ_CONF_PATH, updated_content)
        end
      end
    end
  end
end
