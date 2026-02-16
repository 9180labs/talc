# frozen_string_literal: true

module Talc
  # System helpers for executing commands with sudo and managing systemd services
  class System
    # Check if sudo is available
    def self.sudo_available?
      system('which sudo > /dev/null 2>&1')
    end

    # Execute a command with sudo
    # Returns [stdout, stderr, status]
    def self.sudo_exec(command)
      unless sudo_available?
        raise PermissionError, "sudo is not available. Please install sudo."
      end

      full_command = "sudo #{command}"
      stdout, stderr, status = exec_command(full_command)

      unless status.success?
        raise PermissionError, "Command failed: #{command}\n#{stderr}"
      end

      [stdout, stderr, status]
    end

    # Execute a command without sudo
    # Returns [stdout, stderr, status]
    def self.exec_command(command)
      require 'open3'
      stdout, stderr, status = Open3.capture3(command)
      [stdout, stderr, status]
    end

    # Check if a systemd service is running
    def self.service_running?(service_name)
      stdout, _stderr, status = exec_command("systemctl is-active #{service_name} 2>/dev/null")
      status.success? && stdout.strip == 'active'
    end

    # Check if a systemd service is enabled
    def self.service_enabled?(service_name)
      stdout, _stderr, status = exec_command("systemctl is-enabled #{service_name} 2>/dev/null")
      status.success? && stdout.strip == 'enabled'
    end

    # Start a systemd service
    def self.start_service(service_name)
      sudo_exec("systemctl start #{service_name}")
    end

    # Stop a systemd service
    def self.stop_service(service_name)
      sudo_exec("systemctl stop #{service_name}")
    end

    # Restart a systemd service
    def self.restart_service(service_name)
      sudo_exec("systemctl restart #{service_name}")
    end

    # Reload a systemd service
    def self.reload_service(service_name)
      sudo_exec("systemctl reload #{service_name}")
    end

    # Enable a systemd service
    def self.enable_service(service_name)
      sudo_exec("systemctl enable #{service_name}")
    end

    # Mask a systemd service
    def self.mask_service(service_name)
      sudo_exec("systemctl mask #{service_name}")
    end

    # Unmask a systemd service
    def self.unmask_service(service_name)
      sudo_exec("systemctl unmask #{service_name}")
    end

    # Check if a systemd service is masked
    def self.service_masked?(service_name)
      stdout, _stderr, status = exec_command("systemctl is-enabled #{service_name} 2>/dev/null")
      status.success? && stdout.strip == 'masked'
    end

    # Check if a binary exists at a specific path
    def self.binary_exists?(path)
      File.exist?(path) && File.executable?(path)
    end

    # Check if a package is installed by checking for its binary
    def self.package_installed?(binary_path)
      binary_exists?(binary_path)
    end

    # Write content to a file with sudo
    def self.write_file_sudo(path, content)
      require 'tempfile'

      # Ensure parent directory exists
      dir = File.dirname(path)
      unless Dir.exist?(dir)
        sudo_exec("mkdir -p #{dir}")
      end

      # Write to a temporary file first
      temp_file = Tempfile.new('talc')
      temp_file.write(content)
      temp_file.close

      # Copy with sudo
      sudo_exec("cp #{temp_file.path} #{path}")
      sudo_exec("chmod 644 #{path}")
    ensure
      temp_file&.unlink
    end

    # Read a file that may require sudo
    def self.read_file(path)
      if File.readable?(path)
        File.read(path)
      else
        stdout, _stderr, _status = sudo_exec("cat #{path}")
        stdout
      end
    end

    # Delete a file with sudo
    def self.delete_file_sudo(path)
      sudo_exec("rm -f #{path}")
    end
  end
end
