# frozen_string_literal: true

class Clover
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
        .eager(:semaphores, :location, strand: :children, representative_server: [:strand, vm: :vm_storage_volumes])

      if has_ids
        dataset = dataset.where(Sequel[:postgres_resource][:id] => ids)
      end

      if chc_org_id
        dataset = dataset.where(Sequel.pg_jsonb_op(:tags).contains([{key: "chc_org_id", value: chc_org_id}]))
      end

      {items: Serializers::Postgres.serialize(dataset.all)}
    end
  end
end
