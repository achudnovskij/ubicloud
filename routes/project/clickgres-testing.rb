# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "clickgres-testing") do |r|
    r.on POSTGRES_RESOURCE_NAME_OR_UBID do |pg_name, pg_id|
      filter = pg_name ? {Sequel[:postgres_resource][:name] => pg_name} : {Sequel[:postgres_resource][:id] => pg_id}
      pg = @project.postgres_resources_dataset.first(filter)
      check_found_object(pg)

      r.post api?, "inject-failure" do
        unless ENV["ENABLE_FAILURE_INJECTION"] == "true"
          no_authorization_needed
          raise CloverError.new(403, "Forbidden", "Failure injection is not enabled for this deployment")
        end
        authorize("Postgres:edit", pg)
        postgres_inject_failure(pg, typecast_params.nonempty_str!("failure_type"))
      end

      r.get api?, "convergence" do
        authorize("Postgres:view", pg)
        no_audit_log

        reasons = []
        reasons << "needs_convergence" if pg.needs_convergence?
        reasons << "servers_not_ready" unless pg.has_enough_ready_servers?
        reasons << "ongoing_failover" if pg.ongoing_failover?

        # PostgresResource and PostgresServer have one_to_one :strand, key: :id —
        # strand.id equals the model's id, so we don't need to load the strand.
        strand_ids = pg.servers.map(&:id) + [pg.id]
        pending = DB[:semaphore].where(strand_id: strand_ids).exclude(name: ["checkup", "use_different_az", "use_old_walg_command"]).select_map(:name).uniq
        reasons << "pending_semaphores" if pending.any?

        {converged: reasons.empty?, reasons:, pending_semaphores: pending}
      end
    end
  end
end
