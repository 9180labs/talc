# frozen_string_literal: true

module Talc
  module Proxy
    # Abstract base class for reverse proxy providers
    # Defines the contract that all proxy providers must implement
    class Base
      # Add a route mapping domain to port
      # @param domain [String] The full domain name (e.g., 'myapp.internal')
      # @param port [Integer] The local port to proxy to
      # @param ip [String] The IP address to proxy to (default: '127.0.0.1')
      def add_route(domain, port, ip: '127.0.0.1')
        raise NotImplementedError, "#{self.class} must implement #add_route"
      end

      # Remove a route for the given domain
      # @param domain [String] The full domain name
      def remove_route(domain)
        raise NotImplementedError, "#{self.class} must implement #remove_route"
      end

      # List all routes managed by this provider
      # @return [Array<Hash>] Array of route information
      def list_routes
        raise NotImplementedError, "#{self.class} must implement #list_routes"
      end

      # Reload the proxy service to apply changes
      def reload
        raise NotImplementedError, "#{self.class} must implement #reload"
      end

      # Check if the proxy provider is installed
      # @return [Boolean]
      def installed?
        raise NotImplementedError, "#{self.class} must implement #installed?"
      end

      # Get status of the proxy service
      # @return [Hash] Status information
      def status
        raise NotImplementedError, "#{self.class} must implement #status"
      end
    end
  end
end
