# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Talc
  # JSON-based storage for domain configurations
  # Provides atomic operations with file locking
  class Storage
    DEFAULT_STORAGE_PATH = File.join(Dir.home, '.config', 'talc', 'domains.json')

    attr_reader :storage_path

    def initialize(storage_path: DEFAULT_STORAGE_PATH)
      @storage_path = storage_path
      ensure_storage_exists
    end

    # Get all domains
    def all
      with_lock(:shared) do
        data = read_data
        data['domains'] || []
      end
    end

    # Find a domain by name
    def find(name)
      all.find { |domain| domain['name'] == name }
    end

    # Add a new domain
    def add(name, port, ip: '127.0.0.1')
      with_lock(:exclusive) do
        data = read_data
        domains = data['domains'] || []

        if domains.any? { |d| d['name'] == name }
          raise DomainExistsError, "Domain '#{name}' already exists"
        end

        domain = {
          'name' => name,
          'port' => port,
          'ip' => ip,
          'created_at' => Time.now.iso8601,
          'updated_at' => Time.now.iso8601
        }

        domains << domain
        data['domains'] = domains
        write_data(data)

        domain
      end
    end

    # Remove a domain by name
    def remove(name)
      with_lock(:exclusive) do
        data = read_data
        domains = data['domains'] || []

        domain = domains.find { |d| d['name'] == name }
        raise DomainNotFoundError, "Domain '#{name}' not found" unless domain

        domains.reject! { |d| d['name'] == name }
        data['domains'] = domains
        write_data(data)

        domain
      end
    end

    # Update an existing domain
    def update(name, port: nil, ip: nil)
      with_lock(:exclusive) do
        data = read_data
        domains = data['domains'] || []

        domain = domains.find { |d| d['name'] == name }
        raise DomainNotFoundError, "Domain '#{name}' not found" unless domain

        domain['port'] = port if port
        domain['ip'] = ip if ip
        domain['updated_at'] = Time.now.iso8601

        data['domains'] = domains
        write_data(data)

        domain
      end
    end

    # Clear all domains
    def clear
      with_lock(:exclusive) do
        write_data({ 'domains' => [] })
      end
    end

    private

    def ensure_storage_exists
      dir = File.dirname(@storage_path)

      unless Dir.exist?(dir)
        begin
          FileUtils.mkdir_p(dir)
        rescue Errno::EACCES
          raise StorageError, "Cannot create storage directory: #{dir}. Check permissions."
        end
      end

      unless File.exist?(@storage_path)
        begin
          File.write(@storage_path, JSON.pretty_generate({ 'domains' => [] }))
        rescue Errno::EACCES
          raise StorageError, "Cannot create storage file: #{@storage_path}. Check permissions."
        end
      end
    end

    def with_lock(mode)
      File.open(@storage_path, 'r+') do |file|
        lock_mode = mode == :shared ? File::LOCK_SH : File::LOCK_EX
        file.flock(lock_mode)
        result = yield
        file.flock(File::LOCK_UN)
        result
      end
    rescue Errno::EACCES
      raise StorageError, "Cannot access storage file: #{@storage_path}. Check permissions."
    end

    def read_data
      content = File.read(@storage_path)
      data = JSON.parse(content)
      validate_schema!(data)
      data
    rescue JSON::ParserError => e
      raise StorageError, "Invalid JSON in storage file: #{e.message}"
    end

    def write_data(data)
      File.write(@storage_path, JSON.pretty_generate(data))
    rescue Errno::EACCES
      raise StorageError, "Cannot write to storage file: #{@storage_path}. Check permissions."
    end

    def validate_schema!(data)
      raise StorageError, "Storage data must be a Hash" unless data.is_a?(Hash)
      raise StorageError, "Storage must contain 'domains' key" unless data.key?('domains')
      raise StorageError, "'domains' must be an Array" unless data['domains'].is_a?(Array)
    end
  end
end
