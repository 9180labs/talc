# frozen_string_literal: true

require 'socket'
require 'ipaddr'

module Talc
  # Network utilities for detecting local LAN IP addresses
  class Network
    # Preferred interface order
    PREFERRED_INTERFACES = %w[wlan0 eth0].freeze

    # Detect the local LAN IP address
    # Returns the first private IP found, prioritizing certain interfaces
    def self.detect_local_ip
      addresses = Socket.ip_address_list
                        .select { |addr| addr.ipv4? && !addr.ipv4_loopback? }
                        .map { |addr| { ip: addr.ip_address, interface: addr.inspect_sockaddr } }

      # Filter for private IP ranges
      private_addresses = addresses.select { |addr_info| private_ip?(addr_info[:ip]) }

      raise NetworkError, "No private IP addresses found" if private_addresses.empty?

      # Sort by preferred interfaces
      sorted = private_addresses.sort_by do |addr_info|
        interface_priority(addr_info[:interface])
      end

      sorted.first[:ip]
    end

    # Check if an IP address is in a private range
    def self.private_ip?(ip)
      addr = IPAddr.new(ip)

      private_ranges = [
        IPAddr.new('10.0.0.0/8'),
        IPAddr.new('172.16.0.0/12'),
        IPAddr.new('192.168.0.0/16')
      ]

      private_ranges.any? { |range| range.include?(addr) }
    rescue IPAddr::InvalidAddressError
      false
    end

    # Determine priority of an interface (lower is better)
    def self.interface_priority(interface_info)
      PREFERRED_INTERFACES.each_with_index do |preferred, index|
        return index if interface_info.to_s.include?(preferred)
      end

      # Check for enp* (common Ethernet interface naming)
      return PREFERRED_INTERFACES.size if interface_info.to_s =~ /enp\d+/

      # Default priority for unknown interfaces
      PREFERRED_INTERFACES.size + 1
    end

    private_class_method :interface_priority
  end
end
