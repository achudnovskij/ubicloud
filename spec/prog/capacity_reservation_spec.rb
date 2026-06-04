# frozen_string_literal: true

require "aws-sdk-ec2"

RSpec.describe Prog::CapacityReservation do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
  }

  let(:location_credential_aws) {
    loc = LocationCredentialAws.create_with_id(location, access_key: "test-access-key", secret_key: "test-secret-key")
    LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    LocationAz.create(location_id: loc.id, az: "b", zone_id: "usw2-az2")
    LocationAz.create(location_id: loc.id, az: "c", zone_id: "usw2-az3")
    loc
  }

  let(:client) { Aws::EC2::Client.new(stub_responses: true) }

  # Single-type constraint keeps measure / reconcile expectations crisp.
  let(:default_inputs) {
    {instance_families: {"c6gd" => {"sizes" => ["4xlarge"]}}, additional_capacity: 0.20}
  }

  let(:st) {
    location_credential_aws
    described_class.assemble(location_id: location.id, **default_inputs)
  }

  before do
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(client)
  end

  def az_names = %w[us-west-2a us-west-2b us-west-2c]

  def stub_offerings(azs = az_names, next_token: nil)
    client.stub_responses(:describe_instance_type_offerings,
      {instance_type_offerings: azs.map { {location: it} }, next_token:})
  end

  def stub_reservations(list = [], next_token: nil)
    client.stub_responses(:describe_capacity_reservations,
      {capacity_reservations: list, next_token:})
  end

  def stub_create_modify
    client.stub_responses(:create_capacity_reservation, {capacity_reservation: {capacity_reservation_id: "cr-new"}})
    client.stub_responses(:modify_capacity_reservation, {})
  end

  def api(operation)
    client.api_requests.select { it[:operation_name] == operation }.map { it[:params] }
  end

  # Stub create/modify so each AZ in `limits` (full name => max count) refuses to
  # exceed its cap. Created reservations get the id "cr-<az>" so modify (which
  # carries only the reservation id) can map back to the AZ. Unlisted AZs are
  # uncapped.
  def cap_azs(limits)
    over = ->(az, count) { limits[az] && count > limits[az] }
    client.stub_responses(:create_capacity_reservation, lambda do |ctx|
      az = ctx.params[:availability_zone]
      over.call(az, ctx.params[:instance_count]) ? Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") : {capacity_reservation: {capacity_reservation_id: "cr-#{az}"}}
    end)
    client.stub_responses(:modify_capacity_reservation, lambda do |ctx|
      az = ctx.params[:capacity_reservation_id].delete_prefix("cr-")
      over.call(az, ctx.params[:instance_count]) ? Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") : {}
    end)
  end

  def reload_frame = st.reload.stack.first

  def location_gone_exit = {"msg" => "location is gone; capacity reservation strand exiting"}

  describe ".assemble" do
    it "creates a CapacityReservation strand seeded with the operator inputs" do
      expect(st.prog).to eq("CapacityReservation")
      expect(st.label).to eq("start")
      frame = st.stack.first
      expect(frame["location_id"]).to eq(location.id)
      expect(frame["instance_families"]).to eq({"c6gd" => {"sizes" => ["4xlarge"]}})
      expect(frame["additional_capacity"]).to eq(0.20)
      expect(frame["enable_all_families"]).to be false
      expect(frame["allowed_capacity_decrease"]).to be_nil
      expect(frame["reconcile_interval"]).to eq(described_class::RECONCILE_INTERVAL_SECONDS)
      expect(frame["remove_orphaned_reservations"]).to be false
      expect(frame["current_target"]).to eq({})
      expect(frame["last_observed_usage"]).to eq({})
      expect(frame).not_to have_key("last_measured_at")
    end
  end

  describe ".setup" do
    it "creates a strand when none is live for the location" do
      location_credential_aws
      created = described_class.setup(location_id: location.id, **default_inputs)
      expect(created.prog).to eq("CapacityReservation")
      expect(created.stack.first["additional_capacity"]).to eq(0.20)
      expect(described_class.live_strand(location.id).id).to eq(created.id)
    end

    it "updates the existing live strand instead of creating a second one" do
      location_credential_aws
      first = described_class.setup(location_id: location.id, **default_inputs)
      second = described_class.setup(location_id: location.id,
        instance_families: {"c6gd" => {"sizes" => ["4xlarge"]}}, additional_capacity: 0.40)
      expect(second.id).to eq(first.id)
      expect(Strand.where(prog: "CapacityReservation").count).to eq(1)
      expect(first.reload.stack.first["additional_capacity"]).to eq(0.40)
    end

    it "fails when the location does not exist" do
      expect { described_class.setup(location_id: Strand.generate_uuid, **default_inputs) }
        .to raise_error("No such Location")
    end

    it "fails when the location is not an AWS location" do
      expect { described_class.setup(location_id: Location::HETZNER_FSN1_ID, **default_inputs) }
        .to raise_error(/is not an AWS location/)
    end

    it "fails when the AWS location has no credentials" do
      location # created without location_credential_aws
      expect { described_class.setup(location_id: location.id, **default_inputs) }
        .to raise_error(/no AWS credentials/)
    end

    it "validates inputs before creating" do
      location_credential_aws
      expect { described_class.setup(location_id: location.id, instance_families: {"nope" => {"minimum_cpu" => 8}}, additional_capacity: 0.2) }
        .to raise_error(/Unknown families/)
    end
  end

  describe ".validate_inputs!" do
    def validate(overrides)
      described_class.validate_inputs!({
        "enable_all_families" => false,
        "instance_families" => {"c6gd" => {"minimum_cpu" => 16}},
        "additional_capacity" => 0.2,
      }.merge(overrides))
    end

    it "accepts a valid input set" do
      expect { validate({}) }.not_to raise_error
    end

    it "requires instance_families unless enable_all_families" do
      expect { validate("instance_families" => {}) }.to raise_error("instance_families required")
      expect { validate("instance_families" => {}, "enable_all_families" => true) }.not_to raise_error
    end

    it "rejects a non-finite or out-of-range additional_capacity" do
      expect { validate("additional_capacity" => Float::INFINITY) }.to raise_error(/finite number/)
      expect { validate("additional_capacity" => (0.0 / 0.0)) }.to raise_error(/finite number/)
      expect { validate("additional_capacity" => -1) }.to raise_error(/finite number/)
      expect { validate("additional_capacity" => 20) }.to raise_error(/finite number/)
      expect { validate("additional_capacity" => "x") }.to raise_error(/finite number/)
    end

    it "accepts additional_capacity of exactly 0 and exactly the cap" do
      expect { validate("additional_capacity" => 0) }.not_to raise_error
      expect { validate("additional_capacity" => described_class::MAX_ADDITIONAL_CAPACITY) }.not_to raise_error
    end

    it "accepts a nil allowed_capacity_decrease (ratchet-only)" do
      expect { validate("allowed_capacity_decrease" => nil) }.not_to raise_error
    end

    it "accepts an allowed_capacity_decrease at or above additional_capacity" do
      expect { validate("additional_capacity" => 0.2, "allowed_capacity_decrease" => 0.2) }.not_to raise_error
      expect { validate("additional_capacity" => 0.2, "allowed_capacity_decrease" => 0.5) }.not_to raise_error
    end

    it "rejects an allowed_capacity_decrease below additional_capacity or non-finite" do
      expect { validate("additional_capacity" => 0.2, "allowed_capacity_decrease" => 0.1) }.to raise_error(/>= additional_capacity/)
      expect { validate("allowed_capacity_decrease" => Float::INFINITY) }.to raise_error(/>= additional_capacity/)
      expect { validate("allowed_capacity_decrease" => "x") }.to raise_error(/>= additional_capacity/)
    end

    it "defaults reconcile_interval when absent and accepts a valid override" do
      expect { validate({}) }.not_to raise_error
      expect { validate("reconcile_interval" => 600) }.not_to raise_error
    end

    it "rejects a reconcile_interval below the floor or non-integer" do
      expect { validate("reconcile_interval" => 30) }.to raise_error(/reconcile_interval must be an integer >= 60/)
      expect { validate("reconcile_interval" => 0) }.to raise_error(/reconcile_interval/)
      expect { validate("reconcile_interval" => 300.5) }.to raise_error(/reconcile_interval/)
      expect { validate("reconcile_interval" => "x") }.to raise_error(/reconcile_interval/)
    end

    it "rejects unknown families" do
      expect { validate("instance_families" => {"zzz" => {"minimum_cpu" => 8}}) }.to raise_error(/Unknown families/)
    end

    it "rejects a constraint object with more than one key" do
      expect { validate("instance_families" => {"c6gd" => {"minimum_cpu" => 8, "minimum_storage" => 100}}) }
        .to raise_error(/exactly one key/)
    end

    it "rejects a non-object instance_families and non-object constraints" do
      expect { validate("instance_families" => ["c6gd"]) }.to raise_error(/instance_families must be an object/)
      expect { validate("instance_families" => {"c6gd" => "minimum_cpu"}) }.to raise_error(/must be an object with exactly one key/)
      expect { validate("instance_families" => {"c6gd" => nil}) }.to raise_error(/must be an object with exactly one key/)
    end

    it "rejects a non-numeric minimum_cpu / minimum_storage and a non-array sizes" do
      expect { validate("instance_families" => {"c6gd" => {"minimum_cpu" => "8"}}) }.to raise_error(/minimum_cpu for c6gd must be a number/)
      expect { validate("instance_families" => {"c6gd" => {"minimum_storage" => "200"}}) }.to raise_error(/minimum_storage for c6gd must be a number/)
      expect { validate("instance_families" => {"c6gd" => {"sizes" => "xlarge"}}) }.to raise_error(/sizes for c6gd must be an array/)
    end

    it "rejects an invalid constraint key" do
      expect { validate("instance_families" => {"c6gd" => {"max_cpu" => 8}}) }
        .to raise_error(/Invalid constraint key max_cpu/)
    end

    it "rejects an unknown size for a family in sizes" do
      expect { validate("instance_families" => {"c6gd" => {"sizes" => ["xlarge", "medium"]}}) }
        .to raise_error("Unknown size medium for family c6gd")
    end

    it "rejects a constraint that resolves to no eligible sizes" do
      expect { validate("instance_families" => {"c6gd" => {"minimum_cpu" => 100000}}) }
        .to raise_error(/resolves to no eligible sizes/)
    end

    it "accepts the provisioned cpu/storage constraints" do
      expect { validate("instance_families" => {"c6gd" => {"minimum_provisioned_cpu" => 16}}) }.not_to raise_error
      expect { validate("instance_families" => {"c6gd" => {"minimum_provisioned_storage" => 200}}) }.not_to raise_error
    end

    it "rejects a non-numeric or catalog-unsatisfiable provisioned constraint" do
      expect { validate("instance_families" => {"c6gd" => {"minimum_provisioned_cpu" => "16"}}) }
        .to raise_error(/minimum_provisioned_cpu for c6gd must be a number/)
      # threshold no catalog size in the family can ever meet -> the constraint is dead.
      expect { validate("instance_families" => {"c6gd" => {"minimum_provisioned_cpu" => 100000}}) }
        .to raise_error(/resolves to no eligible sizes/)
    end
  end

  describe ".resolve_eligible_sizes" do
    it "resolves minimum_cpu to all sizes at or above the threshold" do
      expect(described_class.resolve_eligible_sizes("c6gd", {"minimum_cpu" => 16}))
        .to contain_exactly("c6gd.4xlarge", "c6gd.8xlarge", "c6gd.12xlarge", "c6gd.16xlarge")
    end

    it "resolves minimum_storage against the family storage options" do
      expect(described_class.resolve_eligible_sizes("c6gd", {"minimum_storage" => 200}))
        .to contain_exactly("c6gd.xlarge", "c6gd.2xlarge", "c6gd.4xlarge", "c6gd.8xlarge", "c6gd.12xlarge", "c6gd.16xlarge")
    end

    it "resolves an explicit list of instance sizes" do
      expect(described_class.resolve_eligible_sizes("c6gd", {"sizes" => ["xlarge", "2xlarge"]}))
        .to contain_exactly("c6gd.xlarge", "c6gd.2xlarge")
    end

    it "resolves the provisioned cpu/storage variants to the same catalog set as their bare counterparts" do
      expect(described_class.resolve_eligible_sizes("c6gd", {"minimum_provisioned_cpu" => 16}))
        .to eq(described_class.resolve_eligible_sizes("c6gd", {"minimum_cpu" => 16}))
      expect(described_class.resolve_eligible_sizes("c6gd", {"minimum_provisioned_storage" => 200}))
        .to eq(described_class.resolve_eligible_sizes("c6gd", {"minimum_storage" => 200}))
    end

    it "returns nil for an unrecognized constraint key" do
      expect(described_class.resolve_eligible_sizes("c6gd", {"bogus" => 1})).to be_nil
    end
  end

  describe ".update_inputs" do
    it "merges the changed input keys into a free strand, preserving prog state, and returns the strand" do
      nx.update_stack("current_target" => {"c6gd.4xlarge" => {"total" => 6, "per_az" => {}}}, "last_measured_at" => 111)
      expect(described_class.update_inputs(st, {"additional_capacity" => 0.5}).id).to eq(st.id)
      st.reload
      expect(st.stack.first["additional_capacity"]).to eq(0.5)
      expect(st.stack.first["current_target"]).to eq({"c6gd.4xlarge" => {"total" => 6, "per_az" => {}}})
      expect(st.stack.first["last_measured_at"]).to eq(111)
    end

    it "returns nil and skips the write while the strand holds an active lease, so a running pass cannot be clobbered" do
      st.this.update(lease: Sequel::CURRENT_TIMESTAMP + Sequel.cast("100 seconds", :interval))
      expect(described_class.update_inputs(st, {"additional_capacity" => 0.5})).to be_nil
      expect(st.reload.stack.first["additional_capacity"]).to eq(0.20)
    end

    it "with wait:, polls a busy strand and raises once the attempt budget is exhausted" do
      st.this.update(lease: Sequel::CURRENT_TIMESTAMP + Sequel.cast("100 seconds", :interval))
      expect { described_class.update_inputs(st, {"additional_capacity" => 0.5}, wait: true, max_attempts: 2) }.to raise_error(/strand busy/)
      expect(st.reload.stack.first["additional_capacity"]).to eq(0.20)
    end

    it "ignores keys that are not editable inputs" do
      described_class.update_inputs(st, {"additional_capacity" => 0.5, "current_target" => {"x" => 1}})
      st.reload
      expect(st.stack.first["current_target"]).to eq({})
      expect(st.stack.first["additional_capacity"]).to eq(0.5)
    end

    it "validates the resulting input set" do
      expect { described_class.update_inputs(st, {"additional_capacity" => 99}) }.to raise_error(/finite number/)
    end
  end

  describe ".live_strand" do
    it "returns a live strand and ignores exited ones" do
      live = described_class.assemble(location_id: location.id, **default_inputs)
      expect(described_class.live_strand(location.id).id).to eq(live.id)
      live.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "done"}))
      expect(described_class.live_strand(location.id)).to be_nil
    end
  end

  describe "#location_present?" do
    it "is true for a live AWS location with credentials" do
      location_credential_aws
      expect(nx.location_present?).to be true
    end

    it "is false when the location is gone" do
      allow(nx).to receive(:location).and_return(nil)
      expect(nx.location_present?).to be false
    end

    it "is false when the location is no longer AWS" do
      allow(nx).to receive(:location).and_return(instance_double(Location, aws?: false))
      expect(nx.location_present?).to be false
    end

    it "is false when the AWS credentials were cascade-deleted" do
      allow(nx).to receive(:location).and_return(instance_double(Location, aws?: true, location_credential_aws: nil))
      expect(nx.location_present?).to be false
    end
  end

  describe "#start" do
    it "hops to measure when the location is present" do
      location_credential_aws
      expect { nx.start }.to hop("measure")
    end

    it "pages and pops when the location is gone" do
      allow(nx).to receive(:location).and_return(nil)
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/is gone/, ["CapacityReservation", "LocationGone", location.id], [st.ubid], severity: "warning").and_call_original
      expect { nx.start }.to exit(location_gone_exit)
    end
  end

  describe "#compute_current_usage" do
    before { allow(nx).to receive(:location).and_return(location) }

    it "shapes the SQL aggregates into per-type totals and a per-AZ breakdown, normalizing AZ names" do
      allow(nx).to receive(:aggregate_usage).and_return([
        {"c6gd.4xlarge" => 4},
        [
          ["c6gd.4xlarge", "a", 1],
          # a legacy row already holding the full AZ name merges with the bare "a";
          # it is normalized to "us-west-2a", not "us-west-2us-west-2a".
          ["c6gd.4xlarge", "us-west-2a", 1],
          ["c6gd.4xlarge", "b", 1],
          ["c6gd.4xlarge", "us-west-2c", 1],
        ],
      ])

      usage, per_az = nx.compute_current_usage
      expect(usage["c6gd.4xlarge"]).to eq(4)
      expect(per_az["c6gd.4xlarge"]).to eq({"us-west-2a" => 2, "us-west-2b" => 1, "us-west-2c" => 1})
    end

    it "drops sizes that don't resolve to a known VmSize (e.g. a non-AWS size)" do
      allow(nx).to receive(:aggregate_usage).and_return([
        {"c6gd.4xlarge" => 2, "bogus-size" => 5},
        [["bogus-size", "a", 3]],
      ])

      usage, per_az = nx.compute_current_usage
      expect(usage).to eq({"c6gd.4xlarge" => 2})
      expect(per_az).to eq({})
    end

    it "aggregates target counts and per-AZ placement from real DB rows (the SQL path)" do
      location_credential_aws
      resource = create_postgres_resource(project:, location_id: location.id)
      resource.update(target_vm_size: "c6gd.4xlarge", ha_type: "async") # async -> target_server_count 2
      server = create_postgres_server(resource:)
      NicAwsResource.create_with_id(server.vm.nic.id, subnet_az: "a")

      usage, per_az = nx.compute_current_usage
      # target_server_count (2) is intent; only one server is actually placed, so the
      # per-AZ count (1) is deliberately below it -- exercises the join end to end.
      expect(usage).to eq({"c6gd.4xlarge" => 2})
      expect(per_az).to eq({"c6gd.4xlarge" => {"us-west-2a" => 1}})
    end
  end

  describe "#eligible_instance_types" do
    it "is a strict allowlist: only resolved constraint sizes, not observed usage types" do
      # r7gd.large is in current usage but absent from the constraint, so it is
      # deliberately NOT covered; only the listed c6gd.4xlarge is eligible.
      expect(nx.eligible_instance_types({"r7gd.large" => 2}))
        .to contain_exactly("c6gd.4xlarge")
    end

    it "unions resolved constraint sizes with observed usage types when enable_all_families is set" do
      refresh_frame(nx, new_values: {"enable_all_families" => true})
      expect(nx.eligible_instance_types({"r7gd.large" => 2, "c6gd.8xlarge" => 1}))
        .to contain_exactly("c6gd.4xlarge", "r7gd.large", "c6gd.8xlarge")
    end

    it "minimum_provisioned_cpu covers only currently-used sizes meeting the threshold (no pre-warm)" do
      refresh_frame(nx, new_values: {"instance_families" => {"c6gd" => {"minimum_provisioned_cpu" => 16}}})
      # catalog match is {4xlarge,8xlarge,12xlarge,16xlarge}; only the provisioned ones survive.
      # c6gd.large (2 vcpu) is provisioned but below the threshold; c6gd.8xlarge meets it but isn't provisioned.
      expect(nx.eligible_instance_types({"c6gd.4xlarge" => 2, "c6gd.large" => 1}))
        .to contain_exactly("c6gd.4xlarge")
    end

    it "minimum_provisioned_storage covers only currently-used sizes meeting the storage threshold" do
      refresh_frame(nx, new_values: {"instance_families" => {"c6gd" => {"minimum_provisioned_storage" => 200}}})
      expect(nx.eligible_instance_types({"c6gd.2xlarge" => 1, "r7gd.large" => 1}))
        .to contain_exactly("c6gd.2xlarge")
    end
  end

  describe "#measure" do
    before { allow(nx).to receive(:location).and_return(location) }

    it "pages and pops when the location is gone" do
      allow(nx).to receive(:location).and_return(nil)
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/is gone/, ["CapacityReservation", "LocationGone", location.id], [st.ubid], severity: "warning").and_call_original
      expect { nx.measure }.to exit(location_gone_exit)
    end

    it "defers to wait while paused" do
      nx.incr_pause
      expect { nx.measure }.to hop("wait")
    end

    it "pages and processes nothing when the location has fewer than 3 AZs" do
      LocationAz.where(location_id: location.id, az: "c").destroy
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/only 2 AZ/, ["CapacityReservation", "InsufficientAZs", location.display_name], [st.ubid], severity: "warning")
        .and_call_original
      expect { nx.measure }.to hop("reconcile")
      expect(reload_frame["current_target"]).to eq({})
      expect(reload_frame["reconcile_pending"]).to eq([])
      expect(reload_frame["last_measured_at"]).to be_within(5).of(Time.now.to_i)
      expect(reload_frame["azs_insufficient"]).to be true
    end

    it "clears a stale azs_insufficient on a normal pass once the location has >= 3 AZs" do
      refresh_frame(nx, new_values: {"azs_insufficient" => true, "enable_all_families" => true, "instance_families" => {}})
      allow(nx).to receive(:compute_current_usage).and_return([{}, {}])
      expect { nx.measure }.to hop("reconcile")
      expect(reload_frame["azs_insufficient"]).to be false
    end

    context "when sizing" do
      before do
        location_credential_aws
        # Drive eligibility purely from the stubbed usage: clear the constraint so
        # the enable_all_families union does not also pull in the default c6gd.4xlarge.
        refresh_frame(nx, new_values: {"enable_all_families" => true, "instance_families" => {}})
      end

      def measure_with(usage, per_az: {})
        allow(nx).to receive(:compute_current_usage).and_return([usage, per_az])
        expect { nx.measure }.to hop("reconcile")
        reload_frame
      end

      it "applies the +3 buffer floor for zero current usage" do
        frame = measure_with({"c6gd.4xlarge" => 0})
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(3)
        expect(frame["last_observed_usage"]["c6gd.4xlarge"]).to eq({"current" => 0, "buffer" => 3})
      end

      it "lets the +3 floor dominate at small current usage" do
        frame = measure_with({"c6gd.4xlarge" => 5})
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(8)
        expect(frame["last_observed_usage"]["c6gd.4xlarge"]).to eq({"current" => 5, "buffer" => 3})
      end

      it "lets the percentage dominate past the crossover" do
        frame = measure_with({"c6gd.4xlarge" => 20})
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(24)
        expect(frame["last_observed_usage"]["c6gd.4xlarge"]).to eq({"current" => 20, "buffer" => 4})
      end

      it "persists per-AZ usage, the reconcile work list, and the freshness ledger" do
        frame = measure_with({"c6gd.4xlarge" => 5}, per_az: {"c6gd.4xlarge" => {"us-west-2a" => 5}})
        expect(frame["current_usage_per_az"]).to eq({"c6gd.4xlarge" => {"us-west-2a" => 5}})
        expect(frame["reconcile_pending"]).to eq(["c6gd.4xlarge"])
        expect(frame["last_measured_at"]).to be_within(5).of(Time.now.to_i)
      end

      it "orders the reconcile work list biggest instance type first (unresolvable sizes last)" do
        # c6gd.16xlarge=64 vcpu, c6gd.2xlarge=8 vcpu, bogus.size unresolvable (0).
        frame = measure_with({"c6gd.2xlarge" => 1, "c6gd.16xlarge" => 1, "bogus.size" => 1})
        expect(frame["reconcile_pending"]).to eq(["c6gd.16xlarge", "c6gd.2xlarge", "bogus.size"])
      end

      it "ratchets to the previously persisted total when allowed_capacity_decrease is unset" do
        refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 20, "per_az" => {"us-west-2a" => 20}}}})
        frame = measure_with({"c6gd.4xlarge" => 5})
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(20)
        # total is aspirational and written by measure; achieved per_az is preserved.
        expect(frame["current_target"]["c6gd.4xlarge"]["per_az"]).to eq({"us-west-2a" => 20})
      end

      it "carries unmet_azs forward across a measure pass (so first-unmet timestamps survive)" do
        refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 8, "per_az" => {}, "unmet_azs" => {"us-west-2c" => 123}}}})
        frame = measure_with({"c6gd.4xlarge" => 5})
        expect(frame["current_target"]["c6gd.4xlarge"]["unmet_azs"]).to eq({"us-west-2c" => 123})
      end

      it "shrinks in one pass to a current-relative retain buffer larger than the additional_capacity grow buffer" do
        refresh_frame(nx, new_values: {"allowed_capacity_decrease" => 0.5, "current_target" => {"c6gd.4xlarge" => {"total" => 40, "per_az" => {}}}})
        frame = measure_with({"c6gd.4xlarge" => 20})
        # grow target would be 20 + max(ceil(20*0.2),3) = 24, but the shrink floor
        # keeps a 0.5 buffer over current: 20 + ceil(20*0.5) = 30, reached at once.
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(30)
      end

      it "shrinks straight to the additional_capacity target when allowed_capacity_decrease equals additional_capacity" do
        refresh_frame(nx, new_values: {"allowed_capacity_decrease" => 0.2, "current_target" => {"c6gd.4xlarge" => {"total" => 20, "per_az" => {}}}})
        frame = measure_with({"c6gd.4xlarge" => 5})
        # acd == additional_capacity, so the retain floor equals the grow target: 5 + max(ceil(5*0.2),3) = 8.
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(8)
      end

      it "never grows via the shrink path: caps the retain floor at the prior total" do
        refresh_frame(nx, new_values: {"allowed_capacity_decrease" => 0.5, "current_target" => {"c6gd.4xlarge" => {"total" => 20, "per_az" => {}}}})
        frame = measure_with({"c6gd.4xlarge" => 15})
        # grow target 15+max(3,3)=18 < 20 (shrink), but the retain floor 15+ceil(15*0.5)=23 > 20,
        # so we hold at the prior total rather than grow.
        expect(frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(20)
      end

      it "pages and skips an instance type whose target exceeds the per-type ceiling" do
        expect(Prog::PageNexus).to receive(:assemble)
          .with(/exceeds MAX_RESERVED_PER_TYPE/, ["CapacityReservation", "ReservedPerTypeExceeded", location.display_name, "c6gd.4xlarge"], [st.ubid], severity: "warning")
          .and_call_original
        frame = measure_with({"c6gd.4xlarge" => 5000})
        expect(frame["current_target"]).to eq({})
        expect(frame["reconcile_pending"]).to eq([])
      end

      it "pages and skips once the per-location ceiling would be exceeded" do
        usage = {"c6gd.large" => 800, "c6gd.xlarge" => 800, "c6gd.2xlarge" => 800,
                 "c6gd.4xlarge" => 800, "c6gd.8xlarge" => 800, "c6gd.12xlarge" => 800}
        expect(Prog::PageNexus).to receive(:assemble)
          .with(/MAX_RESERVED_PER_LOCATION/, ["CapacityReservation", "ReservedPerLocationExceeded", location.display_name], [st.ubid], severity: "warning")
          .and_call_original
        frame = measure_with(usage)
        # 960 per type; five fit under 5000, the sixth is skipped.
        expect(frame["current_target"].size).to eq(5)
      end
    end

    it "targets only listed types under the strict filter but records per-AZ usage for all running types" do
      location_credential_aws
      # Default frame: enable_all_families=false, instance_families {c6gd => {sizes: [4xlarge]}}.
      allow(nx).to receive(:compute_current_usage).and_return([
        {"c6gd.4xlarge" => 5, "r6gd.large" => 8},
        {"c6gd.4xlarge" => {"us-west-2a" => 5}, "r6gd.large" => {"us-west-2b" => 8}},
      ])
      expect { nx.measure }.to hop("reconcile")
      frame = reload_frame
      expect(frame["current_target"].keys).to eq(["c6gd.4xlarge"]) # only the listed type is reserved
      expect(frame["reconcile_pending"]).to eq(["c6gd.4xlarge"])
      # current_usage_per_az keeps the full observed usage, including the unlisted r6gd.large.
      expect(frame["current_usage_per_az"]).to eq({"c6gd.4xlarge" => {"us-west-2a" => 5}, "r6gd.large" => {"us-west-2b" => 8}})
    end

    it "reads usage from real PostgresResource rows" do
      location_credential_aws
      resource = create_postgres_resource(project:, location_id: location.id)
      resource.update(target_vm_size: "c6gd.4xlarge", ha_type: "sync")
      refresh_frame(nx, new_values: {"enable_all_families" => true})
      expect { nx.measure }.to hop("reconcile")
      expect(reload_frame["current_target"]["c6gd.4xlarge"]["total"]).to eq(6) # 3 servers + max(ceil(0.6),3)=3
    end
  end

  describe "#needs_rebalance?" do
    it "is due when the rebalance semaphore is set" do
      refresh_frame(nx, new_values: {"last_measured_at" => Time.now.to_i})
      nx.incr_rebalance
      expect(nx.needs_rebalance?).to be true
    end

    it "is due when the cadence has elapsed (including a nil ledger)" do
      expect(nx.needs_rebalance?).to be true # last_measured_at absent -> 0
      refresh_frame(nx, new_values: {"last_measured_at" => Time.now.to_i - described_class::RECONCILE_INTERVAL_SECONDS})
      expect(nx.needs_rebalance?).to be true
    end

    it "is not due before the cadence elapses" do
      refresh_frame(nx, new_values: {"last_measured_at" => Time.now.to_i})
      expect(nx.needs_rebalance?).to be false
    end

    it "honors a custom reconcile_interval input" do
      refresh_frame(nx, new_values: {"reconcile_interval" => 60, "last_measured_at" => Time.now.to_i - 90})
      expect(nx.needs_rebalance?).to be true # 90s elapsed >= 60s custom cadence
      refresh_frame(nx, new_values: {"reconcile_interval" => 3600, "last_measured_at" => Time.now.to_i - 90})
      expect(nx.needs_rebalance?).to be false # 90s elapsed < 3600s custom cadence
    end
  end

  describe "#wait" do
    it "naps for 5 minutes while paused so a resume is picked up promptly" do
      nx.incr_pause
      expect { nx.wait }.to nap(5 * 60)
    end

    it "clears the rebalance request and hops to measure when due" do
      nx.incr_rebalance
      expect { nx.wait }.to hop("measure")
      expect(st.semaphores.map(&:name)).not_to include("rebalance")
    end

    it "naps the remaining cadence when not due" do
      refresh_frame(nx, new_values: {"last_measured_at" => Time.now.to_i - 100})
      expect { nx.wait }.to nap(195..205)
    end

    it "clamps the nap to non-negative if the cadence already elapsed (clock skew)" do
      allow(nx).to receive(:needs_rebalance?).and_return(false)
      refresh_frame(nx, new_values: {"reconcile_interval" => 300, "last_measured_at" => Time.now.to_i - 1000})
      expect { nx.wait }.to nap(0)
    end
  end

  describe "#destroy" do
    it "pops and intentionally leaves the ODCRs in place" do
      nx.incr_destroy
      expect { nx.destroy }.to exit("msg" => "capacity reservation strand exited; ODCRs left in place")
    end

    it "naps when destroy was not actually requested" do
      expect { nx.destroy }.to nap(60 * 60 * 24 * 365)
    end
  end

  describe "#even_split_buffer" do
    it "splits evenly when the buffer divides exactly" do
      expect(nx.even_split_buffer(9, az_names, {}))
        .to eq({"us-west-2a" => 3, "us-west-2b" => 3, "us-west-2c" => 3})
    end

    it "awards the extras to the busiest AZ, ties broken by name" do
      expect(nx.even_split_buffer(10, az_names, {}))
        .to eq({"us-west-2a" => 4, "us-west-2b" => 3, "us-west-2c" => 3})
    end

    it "awards extras to the AZ with the most current usage" do
      usage = {"us-west-2a" => 4, "us-west-2b" => 2, "us-west-2c" => 1}
      expect(nx.even_split_buffer(4, az_names, usage))
        .to eq({"us-west-2a" => 2, "us-west-2b" => 1, "us-west-2c" => 1})
    end
  end

  describe "#apply_failure_caps" do
    let(:floor_zero) { az_names.to_h { [it, 0] } }

    it "leaves a compliant split untouched" do
      desired = {"us-west-2a" => 3, "us-west-2b" => 3, "us-west-2c" => 3}
      expect(nx.apply_failure_caps(desired, 9, az_names, floor_zero, {})).to eq(desired)
    end

    it "shaves an AZ over the single-AZ cap and redistributes the surplus" do
      desired = {"us-west-2a" => 6, "us-west-2b" => 2, "us-west-2c" => 2}
      usage = {"us-west-2a" => 4, "us-west-2b" => 0, "us-west-2c" => 0}
      floor = {"us-west-2a" => 4, "us-west-2b" => 0, "us-west-2c" => 0}
      result = nx.apply_failure_caps(desired, 10, az_names, floor, usage)
      expect(result["us-west-2a"]).to eq(5) # floor(10/2)
      expect(result.values.sum).to eq(10)
    end

    it "shaves the two busiest AZs down to the two-AZ cap" do
      desired = {"us-west-2a" => 6, "us-west-2b" => 5, "us-west-2c" => 1}
      result = nx.apply_failure_caps(desired, 12, az_names, floor_zero, {})
      expect(result["us-west-2a"] + result["us-west-2b"]).to eq(10) # floor(5*12/6)
      expect(result.values.sum).to eq(12)
    end

    it "lets a running-VM floor exceed its cap and enforces caps only on the rest" do
      # 4 single-node clusters concentrated in AZ-a: current 4, target 7, cap floor(7/2)=3.
      desired = {"us-west-2a" => 5, "us-west-2b" => 1, "us-west-2c" => 1}
      usage = {"us-west-2a" => 4, "us-west-2b" => 0, "us-west-2c" => 0}
      floor = {"us-west-2a" => 4, "us-west-2b" => 0, "us-west-2c" => 0}
      result = nx.apply_failure_caps(desired, 7, az_names, floor, usage)
      expect(result["us-west-2a"]).to eq(4) # never below the floor, even though > cap
      expect(result.values.sum).to eq(7)
    end

    it "returns nil when the single-AZ surplus cannot be placed under the cap" do
      # target 2 -> single-AZ cap 1; AZ-a wants 5 but the other AZs fill to the cap
      # before the surplus is exhausted.
      desired = {"us-west-2a" => 5, "us-west-2b" => 0, "us-west-2c" => 0}
      expect(nx.apply_failure_caps(desired, 2, az_names, floor_zero, {})).to be_nil
    end

    it "returns nil when the two-AZ cap cannot be satisfied" do
      # All AZs floored at the single-AZ cap so nothing can absorb the two-AZ surplus.
      desired = {"us-west-2a" => 6, "us-west-2b" => 6, "us-west-2c" => 6}
      floor = {"us-west-2a" => 6, "us-west-2b" => 6, "us-west-2c" => 6}
      expect(nx.apply_failure_caps(desired, 12, az_names, floor, {})).to be_nil
    end
  end

  describe "#reconcile" do
    before do
      allow(nx).to receive(:location).and_return(location)
      stub_offerings
      stub_reservations
      stub_create_modify
    end

    it "pages and pops when the location is gone" do
      allow(nx).to receive(:location).and_return(nil)
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/is gone/, ["CapacityReservation", "LocationGone", location.id], [st.ubid], severity: "warning").and_call_original
      expect { nx.reconcile }.to exit(location_gone_exit)
    end

    it "defers to wait while paused" do
      nx.incr_pause
      expect { nx.reconcile }.to hop("wait")
    end

    it "hops to wait when the reconcile work list is empty" do
      refresh_frame(nx, new_values: {"reconcile_pending" => []})
      expect { nx.reconcile }.to hop("wait")
    end

    it "processes the first pending type, persists its per-AZ counts, and naps 0 to continue" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}, "c6gd.8xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {},
        "reconcile_pending" => ["c6gd.4xlarge", "c6gd.8xlarge"],
      })
      expect { nx.reconcile }.to nap(0)
      frame = reload_frame
      expect(frame["current_target"]["c6gd.4xlarge"]["per_az"]).to eq({"us-west-2a" => 3, "us-west-2b" => 3, "us-west-2c" => 3})
      expect(frame["reconcile_pending"]).to eq(["c6gd.8xlarge"])
    end

    it "advances past a type that was paged-and-skipped (nil result) without touching its per-AZ state" do
      stub_offerings(%w[us-west-2a us-west-2b]) # < 3 AZs -> reconcile_instance_type returns nil
      allow(Prog::PageNexus).to receive(:assemble)
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {"us-west-2a" => 7}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      expect { nx.reconcile }.to nap(0)
      frame = reload_frame
      expect(frame["reconcile_pending"]).to eq([])
      expect(frame["current_target"]["c6gd.4xlarge"]["per_az"]).to eq({"us-west-2a" => 7}) # left intact
    end

    it "backs off without advancing the work list when AWS throttles" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      client.stub_responses(:describe_capacity_reservations, Aws::EC2::Errors::RequestLimitExceeded.new(nil, "slow down"))
      expect { nx.reconcile }.to nap(60)
      expect(reload_frame["reconcile_pending"]).to eq(["c6gd.4xlarge"])
    end

    it "pages and skips the type on an ODCR quota error" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      client.stub_responses(:create_capacity_reservation, Aws::EC2::Errors::ReservationCapacityExceeded.new(nil, "quota"))
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/ODCR quota error/, ["CapacityReservation", "ODCRQuotaExceeded", location.display_name, "c6gd.4xlarge"], [st.ubid], severity: "warning")
        .and_call_original
      expect { nx.reconcile }.to nap(0)
      expect(reload_frame["reconcile_pending"]).to eq([])
    end

    it "pages and continues on an unexpected AWS error" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      client.stub_responses(:create_capacity_reservation, Aws::EC2::Errors::InvalidParameterValue.new(nil, "bad"))
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/unexpected AWS error/, ["CapacityReservation", "ReconcileError", location.display_name, "c6gd.4xlarge"], [st.ubid], severity: "warning")
        .and_call_original
      expect { nx.reconcile }.to nap(0)
      expect(reload_frame["reconcile_pending"]).to eq([])
    end

    it "records the AZs AWS could not satisfy as a hash az => first-unmet time" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      cap_azs("us-west-2c" => 0) # AZ-c refuses every reservation
      expect { nx.reconcile }.to nap(0)
      entry = reload_frame["current_target"]["c6gd.4xlarge"]
      expect(entry["unmet_azs"].keys).to eq(["us-west-2c"])
      expect(entry["unmet_azs"]["us-west-2c"]).to be_within(5).of(Time.now.to_i) # stamped now
      expect(entry["per_az"]["us-west-2c"]).to eq(0)
    end

    it "preserves the first-unmet timestamp for an AZ that stays unmet, and pages after a day" do
      long_ago = Time.now.to_i - (described_class::UNMET_PAGE_AFTER + 1)
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}, "unmet_azs" => {"us-west-2c" => long_ago}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      cap_azs("us-west-2c" => 0)
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/unmet in us-west-2c/, ["CapacityReservation", "UnmetCapacity", location.display_name, "c6gd.4xlarge", "us-west-2c"], [st.ubid], severity: "warning").and_call_original
      expect { nx.reconcile }.to nap(0)
      expect(reload_frame["current_target"]["c6gd.4xlarge"]["unmet_azs"]["us-west-2c"]).to eq(long_ago) # not reset
    end

    it "does not page an AZ unmet for less than a day" do
      recent = Time.now.to_i - 60
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}, "unmet_azs" => {"us-west-2c" => recent}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      cap_azs("us-west-2c" => 0)
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect { nx.reconcile }.to nap(0)
    end

    it "clears unmet_azs once the target is fully satisfied" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}, "unmet_azs" => {"us-west-2c" => 123}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      expect { nx.reconcile }.to nap(0) # default stubs let every AZ succeed
      expect(reload_frame["current_target"]["c6gd.4xlarge"]).not_to have_key("unmet_azs")
    end

    it "logs and skips without paging on a state-transition error (e.g. an operator-cancelled ODCR)" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {}, "reconcile_pending" => ["c6gd.4xlarge"],
      })
      client.stub_responses(:modify_capacity_reservation, Aws::EC2::Errors::InvalidStateTransition.new(nil, "mid-transition"))
      stub_reservations(az_names.map { {capacity_reservation_id: "cr-#{it}", availability_zone: it, total_instance_count: 1, state: "active"} })
      allow(Clog).to receive(:emit)
      expect(Clog).to receive(:emit).with("capacity reservation reconcile error", anything)
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect { nx.reconcile }.to nap(0)
      expect(reload_frame["reconcile_pending"]).to eq([]) # skipped this pass, retried next
    end

    it "cancels ODCRs for orphaned types when remove_orphaned_reservations is set" do
      refresh_frame(nx, new_values: {
        "remove_orphaned_reservations" => true,
        "current_target" => {"c6gd.4xlarge" => {"total" => 3, "per_az" => {}}},
        "reconcile_pending" => [],
      })
      stub_reservations([
        {capacity_reservation_id: "cr-keep", availability_zone: "us-west-2a", instance_type: "c6gd.4xlarge", total_instance_count: 1, state: "active"},
        {capacity_reservation_id: "cr-orphan", availability_zone: "us-west-2b", instance_type: "i8ge.2xlarge", total_instance_count: 2, state: "active"},
      ])
      expect { nx.reconcile }.to hop("wait")
      # only the type not in current_target is cancelled; the targeted type is kept.
      expect(api(:cancel_capacity_reservation).map { it[:capacity_reservation_id] }).to eq(["cr-orphan"])
    end

    it "does not sweep orphans when remove_orphaned_reservations is unset (default)" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 3, "per_az" => {}}},
        "reconcile_pending" => [],
      })
      stub_reservations([{capacity_reservation_id: "cr-orphan", availability_zone: "us-west-2b", instance_type: "i8ge.2xlarge", total_instance_count: 2, state: "active"}])
      expect { nx.reconcile }.to hop("wait")
      expect(api(:cancel_capacity_reservation)).to be_empty
    end

    it "does not mass-cancel when the target was zeroed by the InsufficientAZs safety path" do
      refresh_frame(nx, new_values: {
        "remove_orphaned_reservations" => true,
        "current_target" => {},
        "azs_insufficient" => true,
        "reconcile_pending" => [],
      })
      stub_reservations([{capacity_reservation_id: "cr-x", availability_zone: "us-west-2b", instance_type: "i8ge.2xlarge", total_instance_count: 2, state: "active"}])
      expect { nx.reconcile }.to hop("wait")
      expect(api(:cancel_capacity_reservation)).to be_empty
    end

    it "mass-cancels every managed ODCR when the target is legitimately empty (full wind-down)" do
      refresh_frame(nx, new_values: {
        "remove_orphaned_reservations" => true,
        "current_target" => {},
        "azs_insufficient" => false,
        "reconcile_pending" => [],
      })
      stub_reservations([
        {capacity_reservation_id: "cr-1", availability_zone: "us-west-2a", instance_type: "i8ge.2xlarge", total_instance_count: 2, state: "active"},
        {capacity_reservation_id: "cr-2", availability_zone: "us-west-2b", instance_type: "r8gd.medium", total_instance_count: 1, state: "active"},
      ])
      expect { nx.reconcile }.to hop("wait")
      expect(api(:cancel_capacity_reservation).map { it[:capacity_reservation_id] }).to contain_exactly("cr-1", "cr-2")
    end

    it "logs and continues the orphan sweep when a cancel fails" do
      refresh_frame(nx, new_values: {
        "remove_orphaned_reservations" => true,
        "current_target" => {"c6gd.4xlarge" => {"total" => 3, "per_az" => {}}},
        "reconcile_pending" => [],
      })
      stub_reservations([{capacity_reservation_id: "cr-orphan", availability_zone: "us-west-2b", instance_type: "i8ge.2xlarge", total_instance_count: 2, state: "active"}])
      client.stub_responses(:cancel_capacity_reservation, Aws::EC2::Errors::InvalidStateTransition.new(nil, "already cancelled"))
      allow(Clog).to receive(:emit)
      expect(Clog).to receive(:emit).with("capacity reservation orphan cancel error", anything)
      expect { nx.reconcile }.to hop("wait") # the failed cancel does not abort the sweep
    end

    it "paginates the orphan sweep across multiple Describe pages" do
      refresh_frame(nx, new_values: {
        "remove_orphaned_reservations" => true,
        "current_target" => {"c6gd.4xlarge" => {"total" => 3, "per_az" => {}}},
        "reconcile_pending" => [],
      })
      client.stub_responses(:describe_capacity_reservations,
        {capacity_reservations: [{capacity_reservation_id: "cr-1", availability_zone: "us-west-2a", instance_type: "i8ge.2xlarge", total_instance_count: 1, state: "active"}], next_token: "more"},
        {capacity_reservations: [{capacity_reservation_id: "cr-2", availability_zone: "us-west-2b", instance_type: "r8gd.medium", total_instance_count: 1, state: "active"}], next_token: nil})
      expect { nx.reconcile }.to hop("wait")
      expect(api(:cancel_capacity_reservation).map { it[:capacity_reservation_id] }).to contain_exactly("cr-1", "cr-2")
    end
  end

  describe "#reconcile_instance_type" do
    before do
      allow(nx).to receive(:location).and_return(location)
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {},
      })
      stub_offerings
      stub_reservations
      stub_create_modify
    end

    it "returns an empty hash for a type with no recorded target" do
      expect(nx.reconcile_instance_type("c6gd.8xlarge")).to eq({})
    end

    it "derives the family from the type name when it does not resolve to a VmSize" do
      refresh_frame(nx, new_values: {"current_target" => {"x9zd.4xlarge" => {"total" => 9, "per_az" => {}}}})
      nx.reconcile_instance_type("x9zd.4xlarge")
      tags = api(:create_capacity_reservation).first[:tag_specifications].first[:tags].to_h { [it[:key], it[:value]] }
      expect(tags["Ubicloud:Family"]).to eq("x9zd")
    end

    it "creates one open ODCR per AZ for an even split" do
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 3, "us-west-2b" => 3, "us-west-2c" => 3})
      creates = api(:create_capacity_reservation)
      expect(creates.size).to eq(3)
      expect(creates.map { it[:instance_count] }).to eq([3, 3, 3])
      expect(creates.map { it[:availability_zone] }).to match_array(az_names)
      expect(creates.first[:instance_match_criteria]).to eq("open")
      expect(creates.first[:end_date_type]).to eq("unlimited")
    end

    it "tags every ODCR with the canonical and discriminating tags and a per-pass client token" do
      refresh_frame(nx, new_values: {"last_measured_at" => 1_700_000_000})
      nx.reconcile_instance_type("c6gd.4xlarge")
      params = api(:create_capacity_reservation).first
      tags = params[:tag_specifications].first[:tags].to_h { [it[:key], it[:value]] }
      expect(tags["Ubicloud"]).to eq(Config.provider_resource_tag_value)
      expect(tags["component"]).to eq("clickgres")
      expect(tags["Ubicloud:Managed"]).to eq(described_class::MANAGED_TAG_VALUE)
      expect(tags["Ubicloud:LocationId"]).to eq(location.id)
      expect(tags["Ubicloud:Family"]).to eq("c6gd")
      expect(tags["Ubicloud:InstanceType"]).to eq("c6gd.4xlarge")
      expect(tags["Ubicloud:AvailabilityZone"]).to eq("us-west-2a") # full AWS AZ name, not the bare suffix
      expect(params[:client_token]).to eq(Digest::SHA256.hexdigest("cap-res:#{location.id}:c6gd.4xlarge:us-west-2a:3:1700000000"))
    end

    it "uses a distinct client token per InstanceCount so binary-search probes don't collide" do
      # Different-count Creates with the same token would fail with
      # IdempotentParameterMismatch on real AWS; the token must embed the count.
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 24, "per_az" => {}}}, "last_measured_at" => 1_700_000_000})
      capacity = ->(ctx) { (ctx.params[:instance_count] <= 4) ? {capacity_reservation: {capacity_reservation_id: "cr"}} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") }
      client.stub_responses(:create_capacity_reservation, capacity)
      client.stub_responses(:modify_capacity_reservation, ->(ctx) { (ctx.params[:instance_count] <= 4) ? {} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      nx.reconcile_instance_type("c6gd.4xlarge")
      # us-west-2a is probed at count 8 (refused) then 4 (accepted) — two Creates, two tokens.
      a_creates = api(:create_capacity_reservation).select { it[:availability_zone] == "us-west-2a" }
      expect(a_creates.map { it[:instance_count] }).to include(8, 4)
      expect(a_creates.map { it[:client_token] }.uniq.size).to eq(a_creates.size)
      expect(a_creates.find { it[:instance_count] == 8 }[:client_token])
        .to eq(Digest::SHA256.hexdigest("cap-res:#{location.id}:c6gd.4xlarge:us-west-2a:8:1700000000"))
    end

    it "mints a fresh client token each measure pass, so a rebalance after a cancel recreates rather than resurrecting" do
      refresh_frame(nx, new_values: {"last_measured_at" => 1_700_000_000})
      nx.reconcile_instance_type("c6gd.4xlarge")
      first = api(:create_capacity_reservation).find { it[:availability_zone] == "us-west-2a" }[:client_token]

      # A later pass (e.g. a :rebalance after the operator cancelled the ODCR)
      # advances last_measured_at, so the create token differs and AWS mints a
      # genuinely new reservation instead of returning the cancelled one.
      refresh_frame(nx, new_values: {"last_measured_at" => 1_700_000_300})
      nx.reconcile_instance_type("c6gd.4xlarge")
      second = api(:create_capacity_reservation).select { it[:availability_zone] == "us-west-2a" }.last[:client_token]

      expect(second).not_to eq(first)
      expect(second).to eq(Digest::SHA256.hexdigest("cap-res:#{location.id}:c6gd.4xlarge:us-west-2a:3:1700000300"))
    end

    it "modifies rather than creates when an ODCR already exists for the (type, az)" do
      stub_reservations(az_names.map { {capacity_reservation_id: "cr-#{it}", availability_zone: it, total_instance_count: 1, state: "active"} })
      nx.reconcile_instance_type("c6gd.4xlarge")
      expect(api(:create_capacity_reservation)).to be_empty
      expect(api(:modify_capacity_reservation).map { it[:instance_count] }).to eq([3, 3, 3])
    end

    it "skips reconcile (no AWS writes) when existing already meets target, caps, and floors" do
      # target 7; existing a:2,b:2,c:3 (sum 7) covers usage a:1/c:1, single-AZ cap 3
      # (c:3 ok), two-AZ cap floor(35/6)=5 (c:3+b:2=5 ok) -> already acceptable.
      stub_reservations([
        {capacity_reservation_id: "cr-a", availability_zone: "us-west-2a", total_instance_count: 2, state: "active"},
        {capacity_reservation_id: "cr-b", availability_zone: "us-west-2b", total_instance_count: 2, state: "active"},
        {capacity_reservation_id: "cr-c", availability_zone: "us-west-2c", total_instance_count: 3, state: "active"},
      ])
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 7, "per_az" => {}}},
                                     "current_usage_per_az" => {"c6gd.4xlarge" => {"us-west-2a" => 1, "us-west-2c" => 1}}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 2, "us-west-2b" => 2, "us-west-2c" => 3})
      expect(api(:create_capacity_reservation)).to be_empty
      expect(api(:modify_capacity_reservation)).to be_empty
    end

    it "does NOT skip when existing meets the target but violates the two-AZ cap (keeps reconciling)" do
      # a:3+b:3 = 6 exceeds the two-AZ cap floor(5*6/6)=5, so it reshuffles toward 2/2/2.
      stub_reservations([
        {capacity_reservation_id: "cr-a", availability_zone: "us-west-2a", total_instance_count: 3, state: "active"},
        {capacity_reservation_id: "cr-b", availability_zone: "us-west-2b", total_instance_count: 3, state: "active"},
      ])
      refresh_frame(nx, new_values: {"allowed_capacity_decrease" => 0.5,
                                     "current_target" => {"c6gd.4xlarge" => {"total" => 6, "per_az" => {}}},
                                     "current_usage_per_az" => {}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 2, "us-west-2b" => 2, "us-west-2c" => 2})
      expect(api(:modify_capacity_reservation)).not_to be_empty
    end

    it "keeps the largest InstanceCount when describe returns duplicate ODCRs for a (type, az)" do
      # cr-big is listed first so the later, smaller cr-small exercises the
      # "keep the larger, skip this one" dedup branch.
      stub_reservations([
        {capacity_reservation_id: "cr-big", availability_zone: "us-west-2a", total_instance_count: 5, state: "pending"},
        {capacity_reservation_id: "cr-small", availability_zone: "us-west-2a", total_instance_count: 2, state: "active"},
      ])
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 18, "per_az" => {}}}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result["us-west-2a"]).to eq(6) # grown from the deduped count of 5, not 2
      modify_ids = api(:modify_capacity_reservation).map { it[:capacity_reservation_id] }
      expect(modify_ids).to include("cr-big")
      expect(modify_ids).not_to include("cr-small")
    end

    it "pages and skips the type when fewer than 3 AZs offer it" do
      stub_offerings(%w[us-west-2a us-west-2b])
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/only 2 AZ\(s\) available for c6gd.4xlarge/, ["CapacityReservation", "InsufficientAZs", location.display_name, "c6gd.4xlarge"], [st.ubid], severity: "warning")
        .and_call_original
      expect(nx.reconcile_instance_type("c6gd.4xlarge")).to be_nil
      expect(api(:create_capacity_reservation)).to be_empty
    end

    it "narrows the eligible AZ set to those offering the type" do
      # Offerings only list a/b/c even though the location might have more; the
      # location only has a/b/c here, so the result still spans exactly those.
      stub_offerings(%w[us-west-2a us-west-2b us-west-2c us-east-9z])
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result.keys).to match_array(az_names)
    end

    it "reserves current usage first using the per-AZ placement" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}},
        "current_usage_per_az" => {"c6gd.4xlarge" => {"us-west-2a" => 2, "us-west-2b" => 1}},
      })
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result.values.sum).to eq(9)
      expect(result["us-west-2a"]).to be >= 2
      expect(result["us-west-2b"]).to be >= 1
    end

    it "binary-searches a cold AZ down to its capacity limit on InsufficientInstanceCapacity" do
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 24, "per_az" => {}}}})
      capacity = ->(ctx) { (ctx.params[:instance_count] <= 4) ? {capacity_reservation: {capacity_reservation_id: "cr"}} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") }
      client.stub_responses(:create_capacity_reservation, capacity)
      client.stub_responses(:modify_capacity_reservation, ->(ctx) { (ctx.params[:instance_count] <= 4) ? {} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      # Each AZ caps at 4; single-AZ cap is 12 so the top-up cannot exceed real capacity.
      expect(result.values).to all(eq(4))
    end

    it "logs the InsufficientInstanceCapacity shortfall when an AZ cannot reach its target" do
      # Mirrors the real i8ge case: us-west-2c refuses the create entirely, so
      # grow_az degrades to 0 and logs the shortfall the one-shot try_set swallows.
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}}, "current_usage_per_az" => {}})
      cap_azs("us-west-2c" => 0)
      allow(Clog).to receive(:emit)
      expect(Clog).to receive(:emit).with("capacity reservation insufficient capacity",
        hash_including(capacity_reservation_insufficient_capacity: hash_including(az: "us-west-2c", achieved: 0, smallest_attempt: 1))).at_least(:once)
      nx.reconcile_instance_type("c6gd.4xlarge")
    end

    it "creates the +3 floor (1 per AZ) for an explicitly-listed but currently-unused type" do
      # usage 0, target 3, no existing ODCRs: each AZ should still get a 1-instance ODCR.
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 3, "per_az" => {}}}, "current_usage_per_az" => {}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 1, "us-west-2b" => 1, "us-west-2c" => 1})
      expect(api(:create_capacity_reservation).map { it[:instance_count] }).to eq([1, 1, 1])
    end

    it "tops up linearly across AZs, re-probing capacity, and stops once the target is met" do
      # Even split of 6 is 2/2/2; AZ-a refuses anything above 1, so the top-up
      # moves the shortfall onto another AZ and stops the moment the target is met.
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 6, "per_az" => {}}}})
      cap_azs("us-west-2a" => 1)
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result.values.sum).to eq(6)
      expect(result["us-west-2a"]).to eq(1)
    end

    it "stops topping up when no AZ can absorb more, skipping AZs already at the failure-domain cap" do
      # Even split of 8 is 3/3/2; AZ-b and AZ-c are pinned at 1, AZ-a fills to the
      # single-AZ cap (4) and is then skipped, leaving the target unmet.
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 8, "per_az" => {}}}})
      cap_azs("us-west-2b" => 1, "us-west-2c" => 1)
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 4, "us-west-2b" => 1, "us-west-2c" => 1})
      expect(result.values.sum).to be < 8 # capacity exhausted; retried next tick
    end

    it "grows an existing reservation linearly on the growth path" do
      stub_reservations(az_names.map { {capacity_reservation_id: "cr-#{it}", availability_zone: it, total_instance_count: 3, state: "active"} })
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 12, "per_az" => {}}}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 4, "us-west-2b" => 4, "us-west-2c" => 4})
      expect(api(:create_capacity_reservation)).to be_empty
      expect(api(:modify_capacity_reservation).map { it[:instance_count] }).to eq([4, 4, 4])
    end

    it "does not shrink per-AZ counts when allowed_capacity_decrease is unset" do
      stub_reservations(az_names.map { {capacity_reservation_id: "cr-#{it}", availability_zone: it, total_instance_count: 5, state: "active"} })
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(api(:modify_capacity_reservation)).to be_empty
      expect(result.values).to all(eq(5))
    end

    it "shrinks per-AZ counts toward the new split when allowed_capacity_decrease is set" do
      stub_reservations(az_names.map { {capacity_reservation_id: "cr-#{it}", availability_zone: it, total_instance_count: 5, state: "active"} })
      refresh_frame(nx, new_values: {"allowed_capacity_decrease" => 0.5, "current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}}})
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 3, "us-west-2b" => 3, "us-west-2c" => 3})
      expect(api(:modify_capacity_reservation).map { it[:instance_count] }).to eq([3, 3, 3])
    end

    it "cancels an AZ's ODCR when allowed_capacity_decrease drains it to 0 instead of Modifying to 0" do
      # 5 AZs; a and d are cold (no usage) and fall out of the 3-unit buffer split,
      # so their peak reservations must be released. AWS rejects Modify(0) -> cancel.
      allow(nx).to receive(:eligible_azs).and_return(%w[us-west-2a us-west-2b us-west-2c us-west-2d us-west-2f])
      stub_reservations([
        {capacity_reservation_id: "cr-a", availability_zone: "us-west-2a", total_instance_count: 2, state: "active"},
        {capacity_reservation_id: "cr-b", availability_zone: "us-west-2b", total_instance_count: 3, state: "active"},
        {capacity_reservation_id: "cr-c", availability_zone: "us-west-2c", total_instance_count: 4, state: "active"},
        {capacity_reservation_id: "cr-d", availability_zone: "us-west-2d", total_instance_count: 2, state: "active"},
        {capacity_reservation_id: "cr-f", availability_zone: "us-west-2f", total_instance_count: 3, state: "active"},
      ])
      refresh_frame(nx, new_values: {
        "allowed_capacity_decrease" => 0.3,
        "current_target" => {"c6gd.4xlarge" => {"total" => 7, "per_az" => {}}},
        "current_usage_per_az" => {"c6gd.4xlarge" => {"us-west-2b" => 1, "us-west-2c" => 2, "us-west-2f" => 1}},
      })
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result).to eq({"us-west-2a" => 0, "us-west-2b" => 2, "us-west-2c" => 3, "us-west-2d" => 0, "us-west-2f" => 2})
      expect(api(:cancel_capacity_reservation).map { it[:capacity_reservation_id] }).to contain_exactly("cr-a", "cr-d")
      expect(api(:modify_capacity_reservation).map { it[:instance_count] }).not_to include(0)
    end

    it "pages and persists the floors when the failure-domain caps are unsatisfiable" do
      refresh_frame(nx, new_values: {
        "current_target" => {"c6gd.4xlarge" => {"total" => 6, "per_az" => {}}},
        "current_usage_per_az" => {"c6gd.4xlarge" => {"us-west-2a" => 5, "us-west-2b" => 5, "us-west-2c" => 5}},
      })
      expect(Prog::PageNexus).to receive(:assemble)
        .with(/cannot satisfy failure-domain caps/, ["CapacityReservation", "FailureDomainCapUnsatisfiable", location.display_name, "c6gd.4xlarge"], [st.ubid], severity: "warning")
        .and_call_original
      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result.values.sum).to be >= 9 # the running-VM floors are reserved
    end
  end

  describe "#grow_az" do
    before { allow(nx).to receive(:location).and_return(location) }

    it "returns the starting count without calling AWS when the target is not larger" do
      expect(nx.grow_az({}, "c6gd.4xlarge", "us-west-2a", "c6gd", 5, 3, {})).to eq(5)
      expect(client.api_requests).to be_empty
    end

    it "grows an existing reservation linearly and stops at the first capacity shortfall" do
      existing = {"us-west-2a" => {id: "cr-a", count: 3}}
      client.stub_responses(:modify_capacity_reservation,
        ->(ctx) { (ctx.params[:instance_count] <= 4) ? {} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      expect(nx.grow_az(existing, "c6gd.4xlarge", "us-west-2a", "c6gd", 3, 6, {})).to eq(4)
      # tried 6 (fail) then linearly 4 (ok), 5 (fail -> break).
      expect(api(:modify_capacity_reservation).map { it[:instance_count] }).to eq([6, 4, 5])
    end

    it "binary-searches the first-ever cold AZ (no existing ODCR, not yet seen)" do
      client.stub_responses(:create_capacity_reservation,
        ->(ctx) { (ctx.params[:instance_count] <= 2) ? {capacity_reservation: {capacity_reservation_id: "cr"}} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      client.stub_responses(:modify_capacity_reservation,
        ->(ctx) { (ctx.params[:instance_count] <= 2) ? {} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      expect(nx.grow_az({}, "c6gd.4xlarge", "us-west-2a", "c6gd", 0, 5, {})).to eq(2)
      # tried 5 (fail), then binary midpoint 2 (created) — not the linear 1.
      expect(api(:create_capacity_reservation).map { it[:instance_count] }).to eq([5, 2])
    end

    it "grows linearly (not binary) for a previously-seen cold AZ that hit 0" do
      seen = {"us-west-2a" => 0} # recorded by a prior pass that binary-searched to 0
      client.stub_responses(:create_capacity_reservation,
        ->(ctx) { (ctx.params[:instance_count] <= 2) ? {capacity_reservation: {capacity_reservation_id: "cr"}} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      client.stub_responses(:modify_capacity_reservation,
        ->(ctx) { (ctx.params[:instance_count] <= 2) ? {} : Aws::EC2::Errors::InsufficientInstanceCapacity.new(nil, "no") })
      expect(nx.grow_az({}, "c6gd.4xlarge", "us-west-2a", "c6gd", 0, 5, seen)).to eq(2)
      # tried 5 (fail), then linearly from the bottom: 1 (created) — not the binary 2.
      expect(api(:create_capacity_reservation).map { it[:instance_count] }).to eq([5, 1])
    end
  end

  describe "ODCR describe pagination" do
    before do
      allow(nx).to receive(:location).and_return(location)
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 9, "per_az" => {}}}, "current_usage_per_az" => {}})
      stub_create_modify
    end

    it "follows next_token for both offerings and reservations" do
      refresh_frame(nx, new_values: {"current_target" => {"c6gd.4xlarge" => {"total" => 18, "per_az" => {}}}})
      client.stub_responses(:describe_instance_type_offerings,
        {instance_type_offerings: [{location: "us-west-2a"}], next_token: "more"},
        {instance_type_offerings: [{location: "us-west-2b"}, {location: "us-west-2c"}], next_token: nil})
      client.stub_responses(:describe_capacity_reservations,
        {capacity_reservations: [{capacity_reservation_id: "cr-a", availability_zone: "us-west-2a", total_instance_count: 4, state: "active"}], next_token: "more"},
        {capacity_reservations: [], next_token: nil})

      result = nx.reconcile_instance_type("c6gd.4xlarge")
      expect(result.keys).to match_array(az_names)
      # AZ-a (count 4) was discovered on the first describe page and grown via the
      # offerings spanning two pages -> modified, not recreated.
      expect(api(:modify_capacity_reservation).map { it[:capacity_reservation_id] }).to include("cr-a")
      expect(api(:create_capacity_reservation).map { it[:availability_zone] }).not_to include("us-west-2a")
    end
  end
end
