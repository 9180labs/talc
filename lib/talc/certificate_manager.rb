# frozen_string_literal: true

require 'openssl'

module Talc
  # Generates and manages self-signed wildcard TLS certificates for domains
  # Each cert covers the apex domain and *.domain (e.g. myapp.internal and *.myapp.internal)
  class CertificateManager
    DEFAULT_VALIDITY_DAYS = 825

    attr_reader :certs_dir

    def initialize(certs_dir:)
      @certs_dir = File.expand_path(certs_dir)
    end

    # Generate a wildcard certificate for the given full domain (e.g. myapp.internal)
    # Writes cert and key to certs_dir; creates certs_dir with sudo if needed
    # @param full_domain [String] Full domain name (e.g. myapp.internal)
    # @return [Hash] { cert_path:, key_path: }
    def generate_for_domain(full_domain)
      ensure_certs_dir!

      cert_path = path_for_cert(full_domain)
      key_path = path_for_key(full_domain)

      key = OpenSSL::PKey::RSA.new(2048)
      cert = build_certificate(full_domain, key)

      System.write_file_sudo(cert_path, cert.to_pem)
      System.write_file_sudo(key_path, key.to_pem)
      System.sudo_exec("chmod 600 #{key_path}")

      { cert_path: cert_path, key_path: key_path }
    end

    # Path to the certificate file for a domain (may not exist yet)
    def path_for_cert(full_domain)
      File.join(@certs_dir, safe_filename(full_domain) + '.crt')
    end

    # Path to the private key file for a domain (may not exist yet)
    def path_for_key(full_domain)
      File.join(@certs_dir, safe_filename(full_domain) + '.key')
    end

    # Check if a certificate already exists for the domain
    def exists?(full_domain)
      File.exist?(path_for_cert(full_domain)) && File.exist?(path_for_key(full_domain))
    end

    # Remove certificate and key files for a domain
    def remove(full_domain)
      System.delete_file_sudo(path_for_cert(full_domain))
      System.delete_file_sudo(path_for_key(full_domain))
    rescue
      # Best effort
    end

    private

    def ensure_certs_dir!
      return if Dir.exist?(@certs_dir)

      System.sudo_exec("mkdir -p #{@certs_dir}")
      System.sudo_exec("chmod 755 #{@certs_dir}")
    end

    def safe_filename(full_domain)
      full_domain.gsub(/[^a-z0-9.-]/i, '_')
    end

    def build_certificate(full_domain, key)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = Random.rand(1..2**64)
      cert.not_before = Time.now
      cert.not_after = Time.now + (DEFAULT_VALIDITY_DAYS * 24 * 3600)
      cert.public_key = key.public_key

      cert.subject = OpenSSL::X509::Name.new([['CN', full_domain]])
      cert.issuer = cert.subject

      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate = cert

      cert.add_extension(ef.create_extension('basicConstraints', 'CA:FALSE', false))
      cert.add_extension(ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment', false))
      cert.add_extension(ef.create_extension('subjectAltName', "DNS:#{full_domain},DNS:*.#{full_domain}", false))

      cert.sign(key, OpenSSL::Digest.new('SHA256'))
      cert
    end
  end
end
