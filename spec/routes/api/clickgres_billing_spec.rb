# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "clickgres-billing" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:billing_rate_id) { BillingRate.from_resource_properties("PostgresVCpu", "standard-m8gd", "us-west-2")["id"] }
  let(:storage_rate_id) { BillingRate.from_resource_properties("PostgresStorage", "standard", "us-west-2")["id"] }

  def create_billing_record(project_id:, billing_rate_id:, span:, resource_tags: Sequel.pg_jsonb({}))
    BillingRecord.create(
      project_id:,
      resource_id: SecureRandom.uuid,
      resource_name: "test-resource",
      billing_rate_id:,
      amount: 1,
      span: Sequel.pg_range(span),
      resource_tags:,
    )
  end

  before do
    login_api
  end

  describe "GET /project/:project_id/clickgres-billing/postgres-resources" do
    it "requires start_time parameter" do
      expect {
        get "/project/#{project.ubid}/clickgres-billing/postgres-resources?end_time=#{Time.now.utc.iso8601}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: start_time/)
    end

    it "requires end_time parameter" do
      expect {
        get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{(Time.now - 3600).utc.iso8601}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: end_time/)
    end

    it "rejects invalid start_time" do
      expect {
        get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=not-a-date&end_time=#{Time.now.utc.iso8601}"
      }.to raise_error(Committee::InvalidRequest, /not conformant with date-time format/)
    end

    it "rejects end_time before start_time" do
      start_time = Time.now.utc.iso8601
      end_time = (Time.now - 3600).utc.iso8601
      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{start_time}&end_time=#{end_time}"
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("end_time must be after start_time")
    end

    it "returns empty list when no records exist" do
      start_time = (Time.now - 3600).utc.iso8601
      end_time = Time.now.utc.iso8601
      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{start_time}&end_time=#{end_time}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])
    end

    it "returns billing resources overlapping the time range" do
      t1 = Time.now - 3600
      t2 = Time.now
      create_billing_record(
        project_id: project.id,
        billing_rate_id:,
        span: t1..nil,
        resource_tags: Sequel.pg_jsonb({"chc_org_id" => "org-123"}),
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{t2.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      item = body["items"].first
      expect(item["resource_tags"]).to eq({"chc_org_id" => "org-123"})
    end

    it "filters by chc_org_id tag" do
      t1 = Time.now - 3600
      create_billing_record(
        project_id: project.id,
        billing_rate_id:,
        span: t1..nil,
        resource_tags: Sequel.pg_jsonb({"chc_org_id" => "org-123"}),
      )
      create_billing_record(
        project_id: project.id,
        billing_rate_id:,
        span: t1..nil,
        resource_tags: Sequel.pg_jsonb({"chc_org_id" => "org-456"}),
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}&chc_org_id=org-123"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["resource_tags"]["chc_org_id"]).to eq("org-123")
    end

    it "deduplicates by resource_id returning the most recent record" do
      t1 = Time.now - 7200
      t2 = Time.now - 3600
      t3 = Time.now
      resource_id = SecureRandom.uuid

      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id:,
        amount: 1, span: Sequel.pg_range(t1..t2),
        resource_tags: Sequel.pg_jsonb({"version" => "old"}),
      )
      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id:,
        amount: 2, span: Sequel.pg_range(t2..t3),
        resource_tags: Sequel.pg_jsonb({"version" => "new"}),
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{t3.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["resource_tags"]).to eq({"version" => "new"})
    end

    it "collapses multiple billing types for the same resource into one row" do
      t1 = Time.now - 3600
      resource_id = SecureRandom.uuid
      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id:,
        amount: 1, span: Sequel.pg_range(t1..nil),
        resource_tags: Sequel.pg_jsonb({}),
      )
      BillingRecord.create(
        project_id: project.id, resource_id:, resource_name: "test",
        billing_rate_id: storage_rate_id,
        amount: 64, span: Sequel.pg_range(t1..nil),
        resource_tags: Sequel.pg_jsonb({}),
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
    end

    it "excludes records with empty resource_tags (non-postgres resources)" do
      t1 = Time.now - 3600
      create_billing_record(project_id: project.id, billing_rate_id:, span: t1..nil)
      BillingRecord.create(
        project_id: project.id, resource_id: SecureRandom.uuid, resource_name: "vm-resource",
        billing_rate_id:, amount: 1, span: Sequel.pg_range(t1..nil),
        resource_tags: Sequel.pg_jsonb([]),
      )

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["resource_name"]).to eq("test-resource")
    end

    it "scopes to the project in the URL path" do
      t1 = Time.now - 3600
      create_billing_record(project_id: project.id, billing_rate_id:, span: t1..nil)

      other_project = Project.create(name: "other-project")
      create_billing_record(project_id: other_project.id, billing_rate_id:, span: t1..nil)

      get "/project/#{project.ubid}/clickgres-billing/postgres-resources?start_time=#{t1.utc.iso8601}&end_time=#{Time.now.utc.iso8601}"
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
    end
  end

  describe "POST /project/:project_id/clickgres-billing/postgres/:ubid/deactivate" do
    before do
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    def create_pg(name)
      Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location.first.id,
        name:,
        target_vm_size: "standard-2",
        target_storage_size_gib: 128,
      ).subject
    end

    it "increments billing_deactivate semaphore, returns ubid and phase 'pending' when strand is in wait" do
      pg = create_pg("pg-deactivate-1")
      pg.strand.update(label: "wait")

      expect {
        post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      }.to change { Semaphore.where(strand_id: pg.strand.id, name: "billing_deactivate").count }.by(1)

      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["ubid"]).to eq(pg.ubid)
      expect(body["phase"]).to eq("pending")
    end

    it "writes an audit_log row with action billing_deactivate_requested" do
      pg = create_pg("pg-deactivate-audit")
      pg.strand.update(label: "wait")

      expect {
        post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      }.to change { DB[:audit_log].where(Sequel.lit("? = ANY(object_ids)", pg.id)).count }.by(1)

      expect(last_response.status).to eq(200)
      expect(DB[:audit_log].where(action: "billing_deactivate_requested").where(Sequel.lit("? = ANY(object_ids)", pg.id)).count).to eq(1)
    end

    it "does NOT pile up duplicate semaphores OR audit_log rows when polled repeatedly while a deactivate is already in flight" do
      pg = create_pg("pg-deactivate-poll")
      pg.strand.update(label: "wait")

      # First POST kicks off — should write one semaphore row + one audit_log row.
      expect {
        post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      }.to change { Semaphore.where(strand_id: pg.strand.id, name: "billing_deactivate").count }.by(1)
        .and change { DB[:audit_log].where(action: "billing_deactivate_requested").where(Sequel.lit("? = ANY(object_ids)", pg.id)).count }.by(1)

      # Subsequent POSTs (poll-style) while semaphore still queued in wait — no new rows of either kind.
      expect {
        3.times { post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate" }
      }.to not_change { Semaphore.where(strand_id: pg.strand.id, name: "billing_deactivate").count }
        .and not_change { DB[:audit_log].where(action: "billing_deactivate_requested").where(Sequel.lit("? = ANY(object_ids)", pg.id)).count }

      # Strand transitioned into a deactivate phase — still no new rows.
      pg.strand.update(label: "billing_deactivate_wait_backup")
      expect {
        3.times { post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate" }
      }.to not_change { Semaphore.where(strand_id: pg.strand.id, name: "billing_deactivate").count }
        .and not_change { DB[:audit_log].where(action: "billing_deactivate_requested").where(Sequel.lit("? = ANY(object_ids)", pg.id)).count }
    end

    it "returns 404 for an unknown ubid" do
      post "/project/#{project.ubid}/clickgres-billing/postgres/pgqxkxmkdcpp7hj8tppqceat4n/deactivate"
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Postgres resource not found")
    end

    it "maps strand label 'billing_deactivate_suspend' to phase 'suspending'" do
      pg = create_pg("pg-deactivate-suspending")
      pg.strand.update(label: "billing_deactivate_suspend")

      post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["phase"]).to eq("suspending")
    end

    it "maps strand label 'billing_deactivate_wait_backup' to phase 'backup_in_progress'" do
      pg = create_pg("pg-deactivate-wait-backup")
      pg.strand.update(label: "billing_deactivate_wait_backup")

      post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["phase"]).to eq("backup_in_progress")
    end

    it "maps strand label 'destroy' to phase 'destroying'" do
      pg = create_pg("pg-deactivate-destroying")
      pg.strand.update(label: "destroy")

      post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["phase"]).to eq("destroying")
    end

    it "maps strand label 'wait_children_destroyed' to phase 'destroying'" do
      pg = create_pg("pg-deactivate-wait-children")
      pg.strand.update(label: "wait_children_destroyed")

      post "/project/#{project.ubid}/clickgres-billing/postgres/#{pg.ubid}/deactivate"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["phase"]).to eq("destroying")
    end
  end

  describe "POST /project/:project_id/clickgres-billing/postgres-details" do
    before do
      postgres_project = Project.create(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    def create_pg(name, org_id)
      Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id,
        location_id: Location.first.id,
        name:,
        target_vm_size: "standard-2",
        target_storage_size_gib: 128,
        tags: [{key: "chc_org_id", value: org_id}],
      ).subject
    end

    it "returns 400 when neither ids nor chc_org_id is provided" do
      post "/project/#{project.ubid}/clickgres-billing/postgres-details", "{}"
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("At least one of 'ids' or 'chc_org_id' must be provided")
    end

    it "returns 400 for empty ids array" do
      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: []}.to_json
      expect(last_response.status).to eq(400)
    end

    it "returns 400 for invalid id format" do
      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: ["not-a-valid-id"]}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Invalid id format: not-a-valid-id")
    end

    it "returns 400 when ids exceed maximum" do
      ids = Array.new(201) { SecureRandom.uuid }
      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids:}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Maximum of 200 ids allowed per request")
    end

    it "returns resources filtered by ids using UBID format" do
      pg1 = create_pg("pg-test-1", "org-AAA")
      create_pg("pg-test-2", "org-AAA")

      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: [pg1.ubid]}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["id"]).to eq(pg1.ubid)
    end

    it "returns resources filtered by ids using UUID format" do
      pg1 = create_pg("pg-uuid-1", "org-AAA")

      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: [pg1.id]}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["id"]).to eq(pg1.ubid)
    end

    it "returns resources filtered by ids with mixed UBID and UUID formats" do
      pg1 = create_pg("pg-mix-1", "org-AAA")
      pg2 = create_pg("pg-mix-2", "org-BBB")

      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: [pg1.ubid, pg2.id]}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(2)
      returned_ids = body["items"].map { it["id"] }
      expect(returned_ids).to contain_exactly(pg1.ubid, pg2.ubid)
    end

    it "returns resources filtered by chc_org_id only" do
      pg1 = create_pg("pg-org-1", "org-AAA")
      pg2 = create_pg("pg-org-2", "org-AAA")
      create_pg("pg-org-3", "org-BBB")

      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {chc_org_id: "org-AAA"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(2)
      returned_ids = body["items"].map { it["id"] }
      expect(returned_ids).to contain_exactly(pg1.ubid, pg2.ubid)
    end

    it "returns intersection when both ids and chc_org_id are provided" do
      pg1 = create_pg("pg-both-1", "org-AAA")
      pg2 = create_pg("pg-both-2", "org-BBB")

      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: [pg1.ubid, pg2.ubid], chc_org_id: "org-AAA"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["id"]).to eq(pg1.ubid)
    end

    it "returns empty list when no resources match" do
      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {chc_org_id: "org-NONEXISTENT"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])
    end

    it "returns empty list for nonexistent ids" do
      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {ids: ["pgqxkxmkdcpp7hj8tppqceat4n"]}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"]).to eq([])
    end

    it "scopes to the project in the URL path" do
      pg1 = create_pg("pg-scoped-1", "org-AAA")

      other_project = Project.create(name: "other-project")
      Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: other_project.id,
        location_id: Location.first.id,
        name: "pg-other-1",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128,
        tags: [{key: "chc_org_id", value: "org-AAA"}],
      ).subject

      post "/project/#{project.ubid}/clickgres-billing/postgres-details", {chc_org_id: "org-AAA"}.to_json
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body["items"].size).to eq(1)
      expect(body["items"].first["id"]).to eq(pg1.ubid)
    end
  end
end
