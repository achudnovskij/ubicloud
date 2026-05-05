# frozen_string_literal: true

class PostgresServer
  module PrependMethods
    def configure_hash
      result = super
      result.merge(configs: result[:configs].merge(
        "pg_stat_ch.extra_attributes" => "'#{pg_stat_ch_extra_attributes}'",
        "pg_stat_ch.queue_capacity" => pg_stat_ch_queue_capacity.to_s,
        "pg_stat_ch.string_area_size" => pg_stat_ch_string_area_size.to_s,
        "pg_stat_ch.use_otel" => "on",
      ))
    end

    def pg_stat_ch_extra_attributes
      [
        "instance_ubid:#{resource.ubid}",
        "server_ubid:#{ubid}",
        "server_role:#{primary? ? "primary" : "standby"}",
        "region:#{resource.location.name}",
        "host_id:#{vm.aws_instance&.instance_id || vm.vm_host_id}",
      ].join(";")
    end

    # Shmem ring buffer for pending events. Power of 2. Sized by vCPUs since
    # event rate scales with query throughput.
    def pg_stat_ch_queue_capacity
      case vm.vcpus
      when 0..2 then 262_144
      when 3..4 then 524_288
      when 5..8 then 1_048_576
      else 2_097_152
      end
    end

    # DSA pool for in-flight event strings. Sized to ~queue_capacity × 200 B
    # so dsa_oom_count tracks queue saturation, not string-pool exhaustion.
    # Value is in MiB.
    def pg_stat_ch_string_area_size
      case vm.vcpus
      when 0..2 then 64
      when 3..4 then 128
      when 5..8 then 256
      else 512
      end
    end
  end
end
