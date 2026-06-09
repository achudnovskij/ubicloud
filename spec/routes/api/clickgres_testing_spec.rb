# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "clickgres-testing" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  before do
    login_api
    postgres_project = Project.create(name: "default")
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    ENV["ENABLE_FAILURE_INJECTION"] = "true"
  end

  after do
    ENV.delete("ENABLE_FAILURE_INJECTION")
  end

  def create_pg(name)
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name:,
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
    ).subject
  end

  # Temporarily replaces _cmd on the SSH module for the duration of the block,
  # restoring the original method in ensure to prevent leaking across examples.
  def with_stub_sshable(cmds = [], raise_error: nil)
    original = NetSsh::WarnUnsafe::Sshable.instance_method(:_cmd)
    NetSsh::WarnUnsafe::Sshable.define_method(:_cmd) do |cmd, **|
      cmds << cmd
      raise raise_error if raise_error
      ""
    end
    # inject-failure deliberately issues SSH from the route (test tooling gated
    # by ENABLE_FAILURE_INJECTION); bypass the route-spec SSH guard for the block
    # while keeping the _cmd stub so placeholder substitution still happens.
    route_spec, Thread.current[:route_spec] = Thread.current[:route_spec], nil
    yield cmds
  ensure
    Thread.current[:route_spec] = route_spec
    NetSsh::WarnUnsafe::Sshable.define_method(:_cmd, original)
  end

  def inject_failure_path(pg_or_name)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    "/project/#{project.ubid}/clickgres-testing/#{name_or_id}/inject-failure"
  end

  def convergence_path(pg_or_name)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    "/project/#{project.ubid}/clickgres-testing/#{name_or_id}/convergence"
  end

  describe "POST /project/:project_id/clickgres-testing/:pg_name_or_id/inject-failure" do
    it "returns 403 when failure injection is disabled" do
      ENV.delete("ENABLE_FAILURE_INJECTION")
      pg = create_pg("test-pg-disabled")
      post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Failure injection is not enabled for this deployment")
    end

    it "returns 404 for nonexistent postgres resource" do
      post inject_failure_path("nonexistent"), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(404)
    end

    it "rejects missing failure_type at schema validation" do
      pg = create_pg("test-pg-missing")
      expect {
        post inject_failure_path(pg), "{}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: failure_type/)
    end

    it "rejects invalid failure_type at schema validation" do
      pg = create_pg("test-pg-invalid")
      expect {
        post inject_failure_path(pg), {failure_type: "invalid"}.to_json
      }.to raise_error(Committee::InvalidRequest, /isn't part of the enum/)
    end

    it "injects pg_restart failure" do
      pg = create_pg("test-pg-restart")
      version = pg.representative_server.version
      with_stub_sshable do |cmds|
        post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        expect(last_response.status).to eq(204)
        expect(last_response.body).to be_empty
        expect(cmds).to include("sudo pg_ctlcluster #{version} main restart")
      end
    end

    it "propagates SSH errors for pg_restart" do
      pg = create_pg("test-pg-restart-fail")
      with_stub_sshable(raise_error: Errno::ECONNREFUSED) do
        expect {
          post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        }.to raise_error(Errno::ECONNREFUSED)
      end
    end

    it "handles SSH errors gracefully for os_shutdown" do
      pg = create_pg("test-pg-shutdown")
      with_stub_sshable(raise_error: Errno::ECONNRESET) do
        post inject_failure_path(pg), {failure_type: "os_shutdown"}.to_json
        expect(last_response.status).to eq(204)
      end
    end

    it "injects pg_service_stop failure" do
      pg = create_pg("test-pg-svc-stop")
      version = pg.representative_server.version
      with_stub_sshable do |cmds|
        post inject_failure_path(pg), {failure_type: "pg_service_stop"}.to_json
        expect(last_response.status).to eq(204)
        expect(cmds).to include("sudo pg_ctlcluster #{version} main stop -m smart")
      end
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-ubid")
      with_stub_sshable do
        post "/project/#{project.ubid}/clickgres-testing/#{pg.ubid}/inject-failure",
          {failure_type: "pg_restart"}.to_json
        expect(last_response.status).to eq(204)
      end
    end

    it "writes an audit_log row tagged with the failure type" do
      pg = create_pg("test-pg-audit")
      with_stub_sshable do
        expect {
          post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        }.to change { DB[:audit_log].where(action: "inject_failure_pg_restart").count }.by(1)
        expect(last_response.status).to eq(204)
      end
    end

    it "returns 400 when the resource has no representative server" do
      pg = create_pg("test-pg-no-server")
      # Demote all servers so PostgresResource#representative_server returns nil.
      # allow_any_instance_of doesn't work in frozen mode (the model class is frozen).
      pg.servers_dataset.update(is_representative: false)
      post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message"))
        .to eq("No representative server found for this database")
    end
  end

  describe "GET /project/:project_id/clickgres-testing/:pg_name_or_id/convergence" do
    it "is reachable even when failure injection is disabled" do
      ENV.delete("ENABLE_FAILURE_INJECTION")
      pg = create_pg("test-pg-conv-no-gate")
      get convergence_path(pg)
      expect(last_response.status).to eq(200)
    end

    it "returns 404 for nonexistent postgres resource" do
      get convergence_path("nonexistent")
      expect(last_response.status).to eq(404)
    end

    it "reports not converged for a freshly assembled resource" do
      pg = create_pg("test-pg-conv-fresh")
      get convergence_path(pg)
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      # A freshly assembled resource hasn't reached `wait` on its servers yet,
      # so at minimum servers_not_ready should be reported.
      expect(body["reasons"]).to include("servers_not_ready")
    end

    it "reports converged when all checks pass" do
      pg = create_pg("test-pg-conv-ok")
      # Drive real state instead of stubs (allow_any_instance_of doesn't work
      # in frozen mode): move all strands to `wait` and clear assemble-time
      # semaphores like initial_provisioning.
      strand_ids = pg.servers.map(&:id) + [pg.id]
      DB[:strand].where(id: strand_ids).update(label: "wait")
      DB[:semaphore].where(strand_id: strand_ids).delete

      get convergence_path(pg)
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body).to eq("converged" => true, "reasons" => [], "pending_semaphores" => [])
    end

    it "lists each failed check in reasons" do
      pg = create_pg("test-pg-conv-failing")
      # Leave strands at their initial (non-wait) labels → servers_not_ready.
      # incr_recycle_unavailable_server → needs_recycling? → needs_convergence?
      # incr_unplanned_take_over → taking_over? → ongoing_failover?
      # Both also count as pending semaphores.
      server = pg.representative_server
      server.incr_recycle_unavailable_server
      server.incr_unplanned_take_over

      get convergence_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      expect(body["reasons"]).to include("needs_convergence", "servers_not_ready", "ongoing_failover", "pending_semaphores")
    end

    it "reports pending_semaphores excluding checkup, use_different_az, and use_old_walg_command" do
      pg = create_pg("test-pg-conv-sems")
      strand_ids = pg.servers.map(&:id) + [pg.id]
      DB[:strand].where(id: strand_ids).update(label: "wait")
      DB[:semaphore].where(strand_id: strand_ids).delete

      server = pg.representative_server
      server.incr_restart
      server.incr_checkup
      pg.incr_use_different_az
      pg.incr_use_old_walg_command

      get convergence_path(pg)
      body = JSON.parse(last_response.body)
      expect(body["converged"]).to be(false)
      expect(body["reasons"]).to eq(["pending_semaphores"])
      expect(body["pending_semaphores"]).to eq(["restart"])
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-conv-ubid")
      get "/project/#{project.ubid}/clickgres-testing/#{pg.ubid}/convergence"
      expect(last_response.status).to eq(200)
    end

    it "does not write an audit_log row" do
      pg = create_pg("test-pg-conv-audit")
      expect { get convergence_path(pg) }
        .not_to change { DB[:audit_log].where(Sequel.lit("? = ANY(object_ids)", pg.id)).count }
      expect(last_response.status).to eq(200)
    end
  end
end
