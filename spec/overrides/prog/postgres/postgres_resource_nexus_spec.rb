# frozen_string_literal: true

require_relative "../../../prog/postgres/spec_helper"

RSpec.describe Prog::Postgres::PostgresResourceNexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Postgres::PostgresResourceNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource) }
  let(:st) { postgres_resource.strand }
  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:billing_rate_id) { BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", "hetzner-fsn1", false)["id"] }

  let(:override_method) { described_class.instance_method(:create_billing_record) }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  describe "#create_billing_record" do
    it "populates billing record tags from resource tags and properties" do
      postgres_server
      postgres_resource.update(tags: Sequel.pg_jsonb([{"key" => "env", "value" => "prod"}]))

      override_method.bind_call(nx, billing_rate_id:, amount: 1, slot: "primary-vcpu")

      br = BillingRecord.where(resource_id: postgres_resource.id).first
      expect(br.resource_tags["env"]).to eq("prod")
      expect(br.resource_tags["cloud_provider"]).not_to be_nil
      expect(br.resource_tags["region"]).to eq(postgres_resource.location.name)
      expect(br.resource_tags["slot"]).to eq("primary-vcpu")
    end

    # The override is always prepended (OVERRIDE_DIR is set per test suite run, not individual test),
    # Therefore, need to call parent method explicitly to maintain coverage.
    # TODO: work with Ubicloud team to enable parent method tests to test parent method code,
    # even if override exists.
    it "overrides the base create_billing_record" do
      postgres_server
      base_method = nx.method(:create_billing_record).super_method
      expect(base_method).not_to be_nil
      base_method.call(billing_rate_id:, amount: 1, slot: "primary-vcpu")
      br = BillingRecord.where(resource_id: postgres_resource.id).first
      expect(br.resource_tags).to eq({"slot" => "primary-vcpu"})
    end
  end

  describe "#wait" do
    before { postgres_server }

    it "hops to billing_deactivate_suspend when billing_deactivate semaphore is set, before super's nap" do
      nx.incr_billing_deactivate
      expect { nx.wait }.to hop("billing_deactivate_suspend")
    end

    it "delegates to super when billing_deactivate semaphore is not set" do
      expect(nx.method(:wait).super_method).not_to be_nil
      # Sanity: super's wait naps at the end when no other hop fires.
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#billing_deactivate_suspend" do
    before do
      postgres_server
      st.update(label: "billing_deactivate_suspend")
    end

    def mock_server(is_representative:)
      instance_double(PostgresServer, is_representative:).tap do |s|
        allow(s).to receive(:apply_lockout)
      end
    end

    it "registers a destroy deadline, locks out servers (standbys before primary), stamps kickoff time on the stack, triggers backup, and hops to billing_deactivate_wait_backup" do
      primary = mock_server(is_representative: true)
      standby = mock_server(is_representative: false)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary, standby], timeline:)

      expect(timeline).to receive(:incr_take_backup_for_scale_down)
      expect(nx).to receive(:register_deadline).with("destroy", Prog::Postgres::PostgresResourceNexus::BILLING_DEACTIVATE_DEADLINE_SECONDS)
      expect(standby).to receive(:apply_lockout).ordered
      expect(primary).to receive(:apply_lockout).ordered

      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
      expect(st.reload.stack.first["billing_deactivate_kicked_off_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "naps 30 when timeline has no leader, without locking out servers or cascading to replicas (so retries don't pile up dead work)" do
      primary = mock_server(is_representative: true)
      replica = instance_double(PostgresResource)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:leader).and_return(nil)
      allow(nx.postgres_resource).to receive_messages(timeline:)
      allow(nx.postgres_resource).to receive(:read_replicas).and_return([replica])

      expect(primary).not_to receive(:apply_lockout)
      expect(replica).not_to receive(:incr_billing_deactivate)
      expect(timeline).not_to receive(:incr_take_backup_for_scale_down)

      expect { nx.billing_deactivate_suspend }.to nap(30)
    end

    it "hops straight to destroy for resources that share the parent's timeline (read replica)" do
      shared_timeline = instance_double(PostgresTimeline, id: "shared-timeline-id")
      parent = instance_double(PostgresResource, timeline: shared_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, timeline: shared_timeline)
      expect(nx).to receive(:register_deadline).with("destroy", Prog::Postgres::PostgresResourceNexus::BILLING_DEACTIVATE_DEADLINE_SECONDS)
      expect(nx.postgres_resource).not_to receive(:servers)
      expect(shared_timeline).not_to receive(:incr_take_backup_for_scale_down)

      expect { nx.billing_deactivate_suspend }.to hop("destroy")
    end

    it "hops straight to destroy for mid-restore PITR resources that still point at the parent's timeline" do
      # PITR before switch_to_new_timeline: has parent + restore_target, but
      # timeline_id still == parent.timeline.id because the server is still in
      # fetch mode pulling from parent's bucket.
      shared_timeline = instance_double(PostgresTimeline, id: "shared-bucket-tl-id")
      parent = instance_double(PostgresResource, timeline: shared_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, timeline: shared_timeline)

      expect(shared_timeline).not_to receive(:incr_take_backup_for_scale_down)
      expect(nx.postgres_resource).not_to receive(:servers)
      expect { nx.billing_deactivate_suspend }.to hop("destroy")
    end

    it "does NOT short-circuit a post-restore PITR resource that has switched to its own timeline" do
      # After switch_to_new_timeline: same parent_id, but pg.timeline is a fresh
      # timeline distinct from parent.timeline — full deactivate flow is safe.
      primary = mock_server(is_representative: true)
      own_timeline = nx.postgres_resource.timeline
      parent_timeline = instance_double(PostgresTimeline, id: "parent-tl-id")
      parent = instance_double(PostgresResource, timeline: parent_timeline)
      allow(nx.postgres_resource).to receive_messages(parent:, servers: [primary], timeline: own_timeline)
      allow(own_timeline).to receive(:incr_take_backup_for_scale_down)

      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "decrements the billing_deactivate semaphore at entry so it is self-clearing" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_scale_down)

      expect(nx).to receive(:decr_billing_deactivate)
      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "cascades billing_deactivate to each read replica so they are not orphaned when the parent is destroyed" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_scale_down)
      replica_a = instance_double(PostgresResource)
      replica_b = instance_double(PostgresResource)
      allow(nx.postgres_resource).to receive(:read_replicas).and_return([replica_a, replica_b])

      expect(replica_a).to receive(:incr_billing_deactivate)
      expect(replica_b).to receive(:incr_billing_deactivate)
      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
    end

    it "writes the kickoff timestamp under a STRING key so a same-lease hop into wait_backup can fetch it without KeyError" do
      primary = mock_server(is_representative: true)
      timeline = nx.postgres_resource.timeline
      allow(nx.postgres_resource).to receive_messages(servers: [primary], timeline:)
      allow(timeline).to receive(:incr_take_backup_for_scale_down)

      expect { nx.billing_deactivate_suspend }.to hop("billing_deactivate_wait_backup")
      # In-memory stack (no reload) must use a string key — wait_backup fetches via "billing_deactivate_kicked_off_at"
      expect(st.stack.first).to have_key("billing_deactivate_kicked_off_at")
      expect(st.stack.first).not_to have_key(:billing_deactivate_kicked_off_at)
    end
  end

  describe "#billing_deactivate_wait_backup" do
    let(:kicked_off_at) { Time.now.utc - 30 }

    before do
      postgres_server
      st.update(label: "billing_deactivate_wait_backup", stack: [{"billing_deactivate_kicked_off_at" => kicked_off_at.iso8601}])
    end

    it "naps when no completed backup exists yet" do
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)

      expect { nx.billing_deactivate_wait_backup }.to nap(60)
    end

    it "naps when the latest sentinel predates the billing-deactivate kickoff" do
      pre_kickoff = Struct.new(:last_modified).new(kicked_off_at - 60)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([pre_kickoff])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)

      expect { nx.billing_deactivate_wait_backup }.to nap(60)
    end

    it "extends bucket lifecycle and hops to destroy when a sentinel newer than kickoff exists" do
      post_kickoff = Struct.new(:last_modified).new(kicked_off_at + 5)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([post_kickoff])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)

      expect(timeline).to receive(:set_lifecycle_policy).with(expiration_days: Config.billing_deactivate_retention_days)
      expect { nx.billing_deactivate_wait_backup }.to hop("destroy")
    end

    it "uses a stubbed Config.billing_deactivate_retention_days for the lifecycle window" do
      post_kickoff = Struct.new(:last_modified).new(kicked_off_at + 5)
      timeline = nx.postgres_resource.timeline
      allow(timeline).to receive(:backups).and_return([post_kickoff])
      allow(nx.postgres_resource).to receive(:timeline).and_return(timeline)
      allow(Config).to receive(:billing_deactivate_retention_days).and_return(30)

      expect(timeline).to receive(:set_lifecycle_policy).with(expiration_days: 30)
      expect { nx.billing_deactivate_wait_backup }.to hop("destroy")
    end
  end
end
