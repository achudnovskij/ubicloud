#!/usr/bin/env ruby
# frozen_string_literal: true

# :nocov:

require_relative "../loader"
require "aws-sdk-ec2"
require "yaml"

# Script to generate instance availability YAML from AWS APIs
# Usage: ruby bin/generate_instance_availability.rb <output_file_path>
#
class InstanceAvailabilityGenerator
<<<<<<< HEAD
  # Families enabled per-project but intentionally omitted from the YAML so they
  # don't surface in the postgres-location API consumed by external clients.
  HIDDEN_FROM_LOCATIONS_API = %w[m7gd r7gd].freeze

  INSTANCE_FAMILIES = (Option::POSTGRES_FAMILY_OPTIONS.keys & Option::AWS_FAMILY_OPTIONS) - HIDDEN_FROM_LOCATIONS_API

  # Regions to skip (e.g. opt-in regions we don't operate in)
  EXCLUDED_REGIONS = %w[me-south-1 me-central-1].freeze
=======
  # Instance families we're interested in
  INSTANCE_FAMILIES = Option::AWS_FAMILY_OPTIONS
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623

  def initialize
    @data = {"providers" => {"aws" => {"locations" => {}}}}
    @data_mutex = Mutex.new
    @log_mutex = Mutex.new
  end

  def generate
    log "Fetching available AWS regions..."
    regions = fetch_regions
    log "Found #{regions.size} regions: #{regions.join(", ")}"

<<<<<<< HEAD
    env_parallel = ENV["PARALLEL_REGIONS_COUNT"]
    parallel_count = (env_parallel || "10").to_i
    parallel_count = 1 if parallel_count < 1
    log "Parallelism: #{parallel_count} #{env_parallel ? "(from PARALLEL_REGIONS_COUNT)" : "(default)"}"
    log "\nFetching instance types from AWS regions (#{parallel_count} in parallel)..."

    queue = Queue.new
    regions.each { |r| queue << r }
=======
    parallel_count = Integer(ENV.fetch("PARALLEL_REGIONS_COUNT", "10"), 10)
    parallel_count = 1 if parallel_count < 1
    log "\nFetching instance types from #{regions.size} regions (#{parallel_count} in parallel)..."

    queue = Queue.new
    regions.each { queue << it }
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623

    workers = Array.new(parallel_count) do
      Thread.new do
        loop do
          region = begin
            queue.pop(true)
          rescue ThreadError
<<<<<<< HEAD
=======
            # queue drained
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
            break
          end
          log "Processing region: #{region}"
          process_region(region)
        end
      end
    end
    workers.each(&:join)

<<<<<<< HEAD
=======
    # Canonical region order; parallel fetch inserts out of order
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
    @data["providers"]["aws"]["locations"] = @data["providers"]["aws"]["locations"].sort.to_h
    @data
  end

<<<<<<< HEAD
=======
  private

>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
  def log(msg)
    @log_mutex.synchronize { puts msg }
  end

<<<<<<< HEAD
  private

=======
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
  def fetch_regions
    # Use us-east-1 as the default region to query for all available regions
    client = Aws::EC2::Client.new(region: "us-east-1")

    response = client.describe_regions
<<<<<<< HEAD
    all_regions = response.regions.map(&:region_name).sort
    excluded = all_regions & EXCLUDED_REGIONS
    log "Excluding regions: #{excluded.join(", ")}" unless excluded.empty?
    all_regions - EXCLUDED_REGIONS
  rescue Aws::EC2::Errors::ServiceError => e
    puts "Error fetching regions: #{e.message}"
    puts "Falling back to default regions"
=======
    response.regions.map(&:region_name).sort
  rescue Aws::EC2::Errors::ServiceError => e
    log "Error fetching regions: #{e.message}"
    log "Falling back to default regions"
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
    ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1", "eu-central-1", "ap-southeast-1", "ap-northeast-1"]
  end

  def process_region(region)
    client = Aws::EC2::Client.new(region:)

    # Get all instance types available in the region
    instance_types = []
    next_token = nil

    loop do
      response = client.describe_instance_types({
        max_results: 100,
        next_token:,
      })

      instance_types.concat(response.instance_types)
      next_token = response.next_token
      break if next_token.nil?
    end

    # Filter and organize by family
    families = {}

    instance_types.each do |instance_type|
      type_name = instance_type.instance_type
      family = extract_family(type_name)

      # Skip if not in our interested families
      next unless INSTANCE_FAMILIES.include?(family)

      families[family] ||= []
      families[family] << {
        "name" => type_name,
        "vcpus" => instance_type.v_cpu_info.default_v_cpus,
        "memory_gib" => instance_type.memory_info.size_in_mi_b / 1024,
        "storage_size_options" => extract_storage_options(instance_type),
      }
    end

    # Sort sizes within each family
    families.each do |family, sizes|
      sizes.sort_by! { |s| [s["vcpus"], s["memory_gib"]] }
    end

    # Add to data structure if we found any instances
    unless families.empty?
      @data_mutex.synchronize do
        @data["providers"]["aws"]["locations"][region] = {
          "families" => families.sort.to_h.transform_values { |sizes| {"sizes" => sizes} },
        }
      end
    end
  rescue Aws::EC2::Errors::ServiceError => e
    log "Error processing region #{region}: #{e.message}"
  end

  def extract_family(instance_type)
    # Extract family from instance type (e.g., "i8g.large" -> "i8g")
    instance_type.split(".").first
  end

  def extract_storage_options(instance_type)
    # Check if instance storage is supported
    return [] unless instance_type.instance_storage_supported

    # Extract storage information from instance storage
    storage_info = instance_type.instance_storage_info
    return [] if storage_info.nil?

    # Get total storage in GB
    total_storage = storage_info.total_size_in_gb || 0

    (total_storage > 0) ? [total_storage] : []
  end
end

# Main execution
if __FILE__ == $0
  output_file = ARGV[0]
  if output_file.nil? || output_file.empty?
    puts "Usage: #{$0} <output_file_path>"
    puts ""
<<<<<<< HEAD
    puts "Example: #{$0} config/postgres_instance_availability.yaml"
=======
    puts "Example: #{$0} config/instance_availability.yml"
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
    puts ""
    exit 1
  end
  puts "Generating instance availability data to #{output_file}..."
  generator = InstanceAvailabilityGenerator.new
  data = generator.generate

  # Write to YAML file
  File.write(output_file, YAML.dump(data))
  puts "\nInstance availability data written to: #{output_file}"
  puts "Total regions: #{data["providers"]["aws"]["locations"].keys.size}"
  puts "Regions: #{data["providers"]["aws"]["locations"].keys.join(", ")}"
end

# :nocov:
