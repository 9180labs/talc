# frozen_string_literal: true

require 'thor'

module Talc
  # Thor-based CLI for Talc domain management
  class CLI < Thor
    class_option :verbose, type: :boolean, aliases: '-v', desc: 'Verbose output'
    class_option :config, type: :string, desc: 'Path to config file'

    def initialize(*args)
      super
      @verbose = options[:verbose]
    end

    desc 'add DOMAIN --port PORT', 'Add a new domain'
    option :port, type: :numeric, required: true, desc: 'Port to proxy to'
    option :ip, type: :string, default: '127.0.0.1', desc: 'IP address to proxy to'
    def add(domain)
      manager = create_manager

      begin
        manager.add(domain, options[:port], ip: options[:ip])
        full_domain = "#{domain}.#{manager.config.domain_suffix}"

        puts colorize("✓ Domain added successfully!", :green)
        puts "\nDomain: #{colorize(full_domain, :cyan)}"
        puts "Proxy:  #{options[:ip]}:#{options[:port]}"
        puts "\nYou can now access your service at: #{colorize("http://#{full_domain}", :cyan)}"
      rescue DomainExistsError => e
        error(e.message)
      rescue ArgumentError => e
        error(e.message)
      rescue => e
        error("Failed to add domain: #{e.message}")
        verbose_error(e) if @verbose
      end
    end

    desc 'remove DOMAIN', 'Remove a domain'
    def remove(domain)
      manager = create_manager

      begin
        manager.remove(domain)
        puts colorize("✓ Domain '#{domain}' removed successfully!", :green)
      rescue DomainNotFoundError => e
        error(e.message)
      rescue => e
        error("Failed to remove domain: #{e.message}")
        verbose_error(e) if @verbose
      end
    end

    desc 'list', 'List all configured domains'
    option :format, type: :string, default: 'table', enum: %w[table json], desc: 'Output format'
    def list
      manager = create_manager

      begin
        domains = manager.list

        if domains.empty?
          puts "No domains configured yet."
          puts "\nAdd a domain with: #{colorize('talc add myapp --port 3000', :cyan)}"
          return
        end

        if options[:format] == 'json'
          require 'json'
          puts JSON.pretty_generate(domains)
        else
          print_table(domains)
        end
      rescue => e
        error("Failed to list domains: #{e.message}")
        verbose_error(e) if @verbose
      end
    end

    desc 'update DOMAIN', 'Update a domain configuration'
    option :port, type: :numeric, desc: 'New port to proxy to'
    option :ip, type: :string, desc: 'New IP address to proxy to'
    def update(domain)
      unless options[:port] || options[:ip]
        error("You must specify --port and/or --ip")
        return
      end

      manager = create_manager

      begin
        manager.update(domain, port: options[:port], ip: options[:ip])
        puts colorize("✓ Domain '#{domain}' updated successfully!", :green)
      rescue DomainNotFoundError => e
        error(e.message)
      rescue => e
        error("Failed to update domain: #{e.message}")
        verbose_error(e) if @verbose
      end
    end

    desc 'setup', 'Initial setup: configure DNS and proxy services'
    def setup
      puts colorize("Talc Setup", :cyan, :bold)
      puts "=" * 50

      # Check dependencies
      puts "\nChecking dependencies..."

      dnsmasq_installed = System.binary_exists?('/usr/bin/dnsmasq')
      caddy_installed = System.binary_exists?('/usr/bin/caddy')

      if dnsmasq_installed
        puts colorize("  ✓ dnsmasq is installed", :green)
      else
        puts colorize("  ✗ dnsmasq is not installed", :red)
        puts "    Install with: #{colorize('sudo pacman -S dnsmasq', :cyan)}"
      end

      if caddy_installed
        puts colorize("  ✓ Caddy is installed", :green)
      else
        puts colorize("  ✗ Caddy is not installed", :red)
        puts "    Install with: #{colorize('sudo pacman -S caddy', :cyan)}"
      end

      unless dnsmasq_installed && caddy_installed
        error("\nPlease install missing dependencies and run setup again.")
        return
      end

      # Check sudo
      unless System.sudo_available?
        error("\nsudo is required but not available.")
        return
      end

      # Create config directory and file
      puts "\nCreating configuration..."
      begin
        config_path = Config.create_default
        puts colorize("  ✓ Config created at #{config_path}", :green)
      rescue => e
        error("  ✗ Failed to create config: #{e.message}")
        return
      end

      # Create storage directory
      puts "\nCreating storage..."
      begin
        Storage.new
        puts colorize("  ✓ Storage initialized", :green)
      rescue => e
        error("  ✗ Failed to initialize storage: #{e.message}")
        return
      end

      # Configure DNS
      puts "\n#{colorize('WARNING:', :yellow, :bold)} This will modify system DNS settings."
      puts "  - systemd-resolved will be stopped and masked"
      puts "  - /etc/resolv.conf will point to dnsmasq (127.0.0.1)"
      puts "  - Backup will be saved to ~/.config/talc/dns_backup.json"
      puts "  - You can restore with: #{colorize('talc teardown', :cyan)}"

      print "\nContinue? (yes/no): "
      confirmation = $stdin.gets.chomp

      unless confirmation.downcase == 'yes'
        puts "Setup cancelled."
        return
      end

      puts "\nConfiguring DNS..."
      begin
        config = Config.new
        dns = DNS::Dnsmasq.new
        local_ip = config.local_ip || Network.detect_local_ip

        # Check for old architecture before configuring
        if dns.send(:old_architecture_detected?)
          puts colorize("  Old architecture detected. Cleaning up old config files...", :yellow)
        end

        dns.configure(local_ip, config.domain_suffix)
        puts colorize("  ✓ DNS configured for *.#{config.domain_suffix} → #{local_ip}", :green)
        puts colorize("  ✓ dnsmasq listening on localhost:53", :green)
        puts colorize("  ✓ /etc/resolv.conf points to dnsmasq", :green)
        puts colorize("  ✓ systemd-resolved stopped and masked", :green)

        # Enable and start dnsmasq
        unless System.service_enabled?('dnsmasq')
          System.enable_service('dnsmasq')
          puts colorize("  ✓ dnsmasq service enabled", :green)
        end

        unless System.service_running?('dnsmasq')
          System.start_service('dnsmasq')
          puts colorize("  ✓ dnsmasq service started", :green)
        else
          dns.reload
          puts colorize("  ✓ dnsmasq service restarted", :green)
        end

        # Verify dnsmasq is listening on port 53
        sleep 0.5  # Give dnsmasq a moment to bind to the port
        unless dns.send(:listening_on_port_53?)
          port_info = dns.send(:check_port_53_status)
          if port_info[:in_use]
            puts colorize("  ⚠ Warning: Port 53 is in use by: #{port_info[:process]}", :yellow)
            puts colorize("  ⚠ dnsmasq may not be listening on port 53", :yellow)
          else
            puts colorize("  ⚠ Warning: dnsmasq may not be listening on port 53 yet", :yellow)
          end
        else
          puts colorize("  ✓ dnsmasq listening on port 53", :green)
        end

        # Verify DNS resolution
        puts "\n  Verifying DNS resolution..."
        if verify_dns_resolution(config.domain_suffix, local_ip)
          puts colorize("  ✓ DNS verification successful", :green)
        else
          puts colorize("  ⚠ DNS verification failed (may take a moment to propagate)", :yellow)
        end
      rescue => e
        error("  ✗ Failed to configure DNS: #{e.message}")
        verbose_error(e) if @verbose
        return
      end

      # Enable and start Caddy
      puts "\nConfiguring Caddy..."
      begin
        unless System.service_enabled?('caddy')
          System.enable_service('caddy')
          puts colorize("  ✓ Caddy service enabled", :green)
        end

        unless System.service_running?('caddy')
          System.start_service('caddy')
          puts colorize("  ✓ Caddy service started", :green)
        else
          puts colorize("  ✓ Caddy service is running", :green)
        end
      rescue => e
        error("  ✗ Failed to configure Caddy: #{e.message}")
        verbose_error(e) if @verbose
        return
      end

      # Success!
      puts "\n" + "=" * 50
      puts colorize("✓ Setup complete!", :green, :bold)
      puts "\nNext steps:"
      puts "  1. Add a domain:    #{colorize('talc add myapp --port 3000', :cyan)}"
      puts "  2. List domains:    #{colorize('talc list', :cyan)}"
      puts "  3. Check status:    #{colorize('talc status', :cyan)}"
    end

    desc 'status', 'Show status of DNS and proxy services'
    def status
      manager = create_manager

      begin
        status_info = manager.status

        puts colorize("Talc Status", :cyan, :bold)
        puts "=" * 50

        # DNS Status
        dns = status_info[:dns]
        puts "\n#{colorize('DNS (dnsmasq):', :cyan)}"
        puts "  Installed:    #{format_status(dns[:dnsmasq][:installed])}"
        puts "  Running:      #{format_status(dns[:dnsmasq][:running])}"
        puts "  Enabled:      #{format_status(dns[:dnsmasq][:enabled])}"
        puts "  Configured:   #{format_status(dns[:dnsmasq][:configured])}"
        puts "  Port 53:      #{format_status(dns[:dnsmasq][:port])}"

        puts "\n#{colorize('System DNS:', :cyan)}"
        puts "  systemd-resolved: #{format_status(!dns[:systemd_resolved][:running])} (should be stopped)"
        puts "  Masked:           #{format_status(dns[:systemd_resolved][:masked])}"
        puts "  /etc/resolv.conf: #{dns[:resolv_conf][:managed_by_talc] ? colorize('Managed by Talc ✓', :green) : colorize('Not managed ✗', :red)}"

        if dns[:resolv_conf][:content]
          puts "\n#{colorize('  Current resolv.conf:', :cyan)}"
          dns[:resolv_conf][:content].lines.each do |line|
            puts "    #{line.strip}" unless line.strip.empty?
          end
        end

        # Proxy Status
        proxy = status_info[:proxy]
        puts "\n#{colorize('Proxy (Caddy):', :cyan)}"
        puts "  Installed: #{format_status(proxy[:installed])}"
        puts "  Running:   #{format_status(proxy[:running])}"
        puts "  Enabled:   #{format_status(proxy[:enabled])}"
        if proxy.key?(:api_reachable)
          puts "  API:       #{format_status(proxy[:api_reachable])}"
        end

        # Configuration
        puts "\n#{colorize('Configuration:', :cyan)}"
        puts "  Local IP:      #{status_info[:local_ip]}"
        puts "  Domain suffix: .#{status_info[:domain_suffix]}"
        puts "  Domains:       #{status_info[:domains_count]}"

      rescue => e
        error("Failed to get status: #{e.message}")
        verbose_error(e) if @verbose
      end
    end

    desc 'teardown', 'Remove all Talc configuration and domains'
    option :confirm, type: :boolean, desc: 'Skip confirmation prompt'
    def teardown
      unless options[:confirm]
        puts colorize("WARNING:", :red, :bold)
        puts "This will remove:"
        puts "  - All configured domains"
        puts "  - DNS configuration (/etc/dnsmasq.d/talc.conf)"
        puts "  - Proxy configuration (Caddy routes)"
        puts "  - Domain storage (~/.config/talc/domains.json)"
        puts "\nThis will restore:"
        puts "  - Original /etc/resolv.conf"
        puts "  - systemd-resolved service (if it was running)"
        puts "  - Your original DNS setup"

        print "\nAre you sure? Type 'yes' to confirm: "
        confirmation = $stdin.gets.chomp

        unless confirmation.downcase == 'yes'
          puts "Teardown cancelled."
          return
        end
      end

      manager = create_manager

      begin
        manager.teardown
        puts colorize("✓ Talc configuration removed successfully!", :green)
      rescue => e
        error("Failed to teardown: #{e.message}")
        verbose_error(e) if @verbose
      end
    end

    desc 'version', 'Show version'
    def version
      puts "Talc version #{Talc::VERSION}"
    end

    private

    def verify_dns_resolution(domain_suffix, expected_ip)
      require 'resolv'
      require 'timeout'

      test_domain = "test.#{domain_suffix}"
      begin
        Timeout.timeout(3) do
          resolver = Resolv::DNS.new
          result = resolver.getaddress(test_domain).to_s
          return result == expected_ip
        end
      rescue
        return false
      end
    end

    def create_manager
      config_path = options[:config] ? { config_path: options[:config] } : {}
      config = Config.new(**config_path)
      DomainManager.new(config: config)
    end

    def colorize(text, *colors)
      # Simple colorization - can be enhanced with pastel gem
      color_codes = {
        red: 31,
        green: 32,
        yellow: 33,
        cyan: 36,
        bold: 1
      }

      codes = colors.map { |c| color_codes[c] }.compact

      if codes.empty?
        text
      else
        "\e[#{codes.join(';')}m#{text}\e[0m"
      end
    end

    def error(message)
      puts colorize("Error: #{message}", :red)
      exit 1
    end

    def verbose_error(exception)
      puts "\n" + colorize("Detailed error information:", :yellow)
      puts exception.full_message
    end

    def format_status(value)
      if value
        colorize("✓", :green)
      else
        colorize("✗", :red)
      end
    end

    def print_table(domains)
      # Simple table printing
      puts "\n#{colorize('Configured Domains:', :cyan, :bold)}\n\n"

      # Calculate column widths
      name_width = [domains.map { |d| d['name'].length }.max, 10].max
      domain_width = [domains.map { |d| d['full_domain'].length }.max, 15].max

      # Header
      puts "  %-#{name_width}s  %-#{domain_width}s  %-15s  %s" % ['NAME', 'FULL DOMAIN', 'PROXY', 'UPDATED']
      puts "  " + "-" * (name_width + domain_width + 40)

      # Rows
      domains.each do |domain|
        proxy = "#{domain['ip']}:#{domain['port']}"
        updated = Time.parse(domain['updated_at']).strftime('%Y-%m-%d %H:%M')

        puts "  %-#{name_width}s  %-#{domain_width}s  %-15s  %s" % [
          domain['name'],
          colorize(domain['full_domain'], :cyan),
          proxy,
          updated
        ]
      end

      puts "\n"
    end
  end
end
