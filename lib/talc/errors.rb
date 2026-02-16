# frozen_string_literal: true

module Talc
  # Base error class for all Talc exceptions
  class Error < StandardError; end

  # Configuration-related errors
  class ConfigError < Error; end

  # DNS provider errors
  class DNSError < Error; end

  # Proxy provider errors
  class ProxyError < Error; end

  # Storage operation errors
  class StorageError < Error; end

  # Network detection errors
  class NetworkError < Error; end

  # Permission/sudo errors
  class PermissionError < Error; end

  # Domain already exists
  class DomainExistsError < Error; end

  # Domain not found
  class DomainNotFoundError < Error; end

  # System service errors
  class ServiceError < Error; end
end
