# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "clickgres-testing") do |r|
    unless ENV["ENABLE_FAILURE_INJECTION"] == "true"
      no_authorization_needed
      raise CloverError.new(403, "Forbidden", "Failure injection is not enabled for this deployment")
    end

    r.on POSTGRES_RESOURCE_NAME_OR_UBID do |pg_name, pg_id|
      filter = pg_name ? {Sequel[:postgres_resource][:name] => pg_name} : {Sequel[:postgres_resource][:id] => pg_id}
      pg = @project.postgres_resources_dataset.first(filter)
      check_found_object(pg)

      r.post api?, "inject-failure" do
        authorize("Postgres:edit", pg)
        postgres_inject_failure(pg, typecast_params.nonempty_str!("failure_type"))
      end
    end
  end
end
