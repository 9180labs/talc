# frozen_string_literal: true

require "test_helper"

class TestTalc < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Talc::VERSION
  end

  def test_error_classes_exist
    assert defined?(Talc::Error)
    assert defined?(Talc::ConfigError)
    assert defined?(Talc::DNSError)
    assert defined?(Talc::ProxyError)
    assert defined?(Talc::StorageError)
    assert defined?(Talc::NetworkError)
    assert defined?(Talc::PermissionError)
    assert defined?(Talc::DomainExistsError)
    assert defined?(Talc::DomainNotFoundError)
    assert defined?(Talc::ServiceError)
  end

  def test_modules_exist
    assert defined?(Talc::Config)
    assert defined?(Talc::Storage)
    assert defined?(Talc::Network)
    assert defined?(Talc::System)
    assert defined?(Talc::DNS::Base)
    assert defined?(Talc::DNS::Dnsmasq)
    assert defined?(Talc::Proxy::Base)
    assert defined?(Talc::Proxy::CaddyAPI)
    assert defined?(Talc::Proxy::CaddyFile)
    assert defined?(Talc::DomainManager)
    assert defined?(Talc::CLI)
  end

  def test_network_detects_private_ip_ranges
    assert Talc::Network.private_ip?('192.168.1.1')
    assert Talc::Network.private_ip?('10.0.0.1')
    assert Talc::Network.private_ip?('172.16.0.1')
    refute Talc::Network.private_ip?('8.8.8.8')
    refute Talc::Network.private_ip?('1.1.1.1')
  end
end
