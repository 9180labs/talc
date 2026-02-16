# frozen_string_literal: true

module Talc
  module DNS
    # Abstract base class for DNS providers
    # Defines the contract that all DNS providers must implement
    class Base
      # Configure DNS for the given local IP and domain suffix
      # @param local_ip [String] The local LAN IP address
      # @param domain_suffix [String] The domain suffix (e.g., 'internal')
      def configure(local_ip, domain_suffix)
        raise NotImplementedError, "#{self.class} must implement #configure"
      end

      # Reload the DNS service to apply configuration changes
      def reload
        raise NotImplementedError, "#{self.class} must implement #reload"
      end

      # Check the status of the DNS service
      # @return [Hash] Status information including :running and :enabled
      def status
        raise NotImplementedError, "#{self.class} must implement #status"
      end

      # Check if the DNS provider is installed
      # @return [Boolean]
      def installed?
        raise NotImplementedError, "#{self.class} must implement #installed?"
      end
    end
  end
end
