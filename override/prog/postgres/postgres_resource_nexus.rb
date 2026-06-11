# frozen_string_literal: true

class Prog::Postgres::PostgresResourceNexus
  BILLING_DEACTIVATE_DEADLINE_SECONDS = 3 * 60 * 60

  label :billing_deactivate_suspend
  label :billing_deactivate_wait_backup

  frame_accessor :billing_deactivate_kicked_off_at

  module PrependMethods
    def create_billing_record(billing_rate_id:, amount:, slot:)
      location = postgres_resource.location

      flattened_tags = (postgres_resource.tags || []).each_with_object({}) do |tag, hash|
        hash[tag["key"]] = tag["value"]
      end

      BillingRecord.create(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id:,
        amount:,
        resource_tags: Sequel.pg_jsonb({
          **flattened_tags,
          cloud_provider: location.provider,
          region: location.name,
          size: postgres_resource.target_vm_size,
          ha_type: postgres_resource.ha_type,
          flavor: postgres_resource.flavor,
          server_count: postgres_resource.target_server_count,
          storage_size_gib: representative_server.storage_size_gib,
          slot:,
        }),
      )
    end

    # Check our semaphore BEFORE super so we hop into billing_deactivate_suspend
    # before super's terminal `nap 30` would exit the method.
    def wait
      when_billing_deactivate_set? do
        hop_billing_deactivate_suspend
      end
      super
    end

    def billing_deactivate_suspend
      decr_billing_deactivate
      register_deadline("destroy", BILLING_DEACTIVATE_DEADLINE_SECONDS)

      # Resources that share their parent's timeline must not run the full
      # flow — backup/lifecycle mutations on the shared bucket would touch
      # the parent's data. This covers:
      #   - Read replicas: always fetch from parent.timeline.
      #   - PITR restores: assemble with parent.timeline (fetch) and only
      #     switch_to_new_timeline after wait_recovery_completion. Calling
      #     deactivate before that switch means we still share the bucket.
      timeline = postgres_resource.timeline
      parent = postgres_resource.parent
      hop_destroy if parent && timeline == parent.timeline

      if timeline.leader.nil?
        # Leader missing (mid-failover or unhealthy primary). Nap and retry —
        # the 3h destroy deadline above will eventually page oncall if leader
        # never appears. Do NOT lockout/cascade/incr-backup yet: those steps
        # need a leader to be meaningful and we'd duplicate work on each retry.
        Clog.emit("billing_deactivate_no_leader_at_kick_off", {pg_ubid: postgres_resource.ubid})
        nap 30
      end

      # Cascade to read replicas in parallel with our own backup wait. The FK
      # was dropped (migrate/20231208_drop_pg_foreign_key_constraints.rb), so
      # nothing else cleans them up when the parent goes away.
      postgres_resource.read_replicas.each(&:incr_billing_deactivate)

      postgres_resource.servers.sort_by { it.is_representative ? 1 : 0 }.each do |server|
        server.apply_lockout
      end

      # Record kickoff time so billing_deactivate_wait_backup blocks until a
      # backup completed *after* the lockout — any pre-existing backup is older
      # than the customer's last writes and must not satisfy the gate.
      self.billing_deactivate_kicked_off_at = Time.now.utc.iso8601
      # Reuse the upstream "force a fresh backup now" semaphore — same mechanism
      # as the converge path, distinct kickoff-timestamp gate keeps the
      # two flows from being confused.
      timeline.incr_take_backup_for_converge
      hop_billing_deactivate_wait_backup
    end

    def billing_deactivate_wait_backup
      kicked_off_at = Time.parse(billing_deactivate_kicked_off_at)
      latest_completed = postgres_resource.timeline.backups.map(&:last_modified).max
      nap 60 if latest_completed.nil? || latest_completed < kicked_off_at

      postgres_resource.timeline.set_lifecycle_policy(expiration_days: Config.billing_deactivate_retention_days)
      hop_destroy
    end
  end
end
