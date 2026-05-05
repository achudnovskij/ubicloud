# frozen_string_literal: true

class Prog::Postgres::PostgresResourceNexus
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
  end
end
