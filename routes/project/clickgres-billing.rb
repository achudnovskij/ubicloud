# frozen_string_literal: true

class Clover
  BILLING_DEACTIVATE_PHASE_BY_LABEL = {
    "billing_deactivate_suspend" => "suspending",
    "billing_deactivate_wait_backup" => "backup_in_progress",
    "destroy" => "destroying",
    "wait_children_destroyed" => "destroying",
  }.freeze

  hash_branch(:project_prefix, "clickgres-billing") do |r|
    r.get "postgres-resources" do
      # Project ownership enforced by parent route; no finer-grained RBAC needed for this machine-to-machine API.
      no_authorization_needed

      start_time, end_time = typecast_params.str(%w[start_time end_time])
      start_time = Validation.validate_rfc3339_datetime_str(start_time, "start_time")
      end_time = Validation.validate_rfc3339_datetime_str(end_time, "end_time")

      if end_time < start_time
        raise CloverError.new(400, "InvalidRequest", "end_time must be after start_time")
      end

      dataset = BillingRecord
        .where(project_id: @project.id)
        .where(Sequel.lit("jsonb_typeof(resource_tags) = 'object'"))
        .overlapping(start_time, end_time)

      # Filtering by chc_org_id scopes results to ClickGres-managed postgres resources.
      if (chc_org_id = typecast_params.str("chc_org_id"))
        dataset = dataset.with_tag("chc_org_id", chc_org_id)
      end

      dataset = dataset.distinct_by_resource

      {items: Serializers::BillingResource.serialize(dataset.all)}
    end

    r.post "postgres-details" do
      no_authorization_needed
      no_audit_log

      ids = typecast_params.array(:str, "ids")
      chc_org_id = typecast_params.nonempty_str("chc_org_id")
      has_ids = ids&.any?

      unless has_ids || chc_org_id
        raise CloverError.new(400, "InvalidRequest", "At least one of 'ids' or 'chc_org_id' must be provided")
      end

      if has_ids
        raise CloverError.new(400, "InvalidRequest", "Maximum of 200 ids allowed per request") if ids.length > 200

        uuid_re = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/i
        ids = ids.map do
          uuid = UBID.to_uuid(it)
          next uuid if uuid
          raise CloverError.new(400, "InvalidRequest", "Invalid id format: #{it}") unless uuid_re.match?(it)
          it
        end
      end

      dataset = @project.postgres_resources_dataset
        .eager(:semaphores, :location, strand: :children, representative_server: [:strand, :semaphores, vm: :vm_storage_volumes])

      if has_ids
        dataset = dataset.where(Sequel[:postgres_resource][:id] => ids)
      end

      if chc_org_id
        dataset = dataset.where(Sequel.pg_jsonb_op(:tags).contains([{key: "chc_org_id", value: chc_org_id}]))
      end

      {items: Serializers::Postgres.serialize(dataset.all)}
    end

    r.on "postgres", String do |ubid|
      r.post "deactivate" do
        no_authorization_needed

        pg = @project.postgres_resources_dataset.first(id: UBID.to_uuid(ubid))
        raise CloverError.new(404, "ResourceNotFound", "Postgres resource not found") unless pg

        # The endpoint is poll-friendly (billing keeps calling to track phase),
        # so the meaningful "request" event is only the first call that actually
        # signals the strand — subsequent calls are status checks and shouldn't
        # spam the audit log or pile up dead semaphore rows on the strand.
        in_deactivate_phase = BILLING_DEACTIVATE_PHASE_BY_LABEL.key?(pg.strand.label)
        if !in_deactivate_phase && !pg.billing_deactivate_set?
          pg.incr_billing_deactivate
          audit_log(pg, "billing_deactivate_requested")
        else
          no_audit_log
        end
        phase = BILLING_DEACTIVATE_PHASE_BY_LABEL[pg.strand.label] || "pending"
        {ubid: pg.ubid, phase:}
      end
    end
  end
end
