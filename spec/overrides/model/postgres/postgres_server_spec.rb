# frozen_string_literal: true

require_relative "../../../model/spec_helper"

RSpec.describe PostgresServer::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:postgres_server) {
    PostgresServer.create(
      timeline:, resource:, vm_id: vm.id, is_representative: true,
      synchronization_status: "ready", timeline_access: "push", version: "16",
    )
  }

  let(:project) { Project.create(name: "postgres-server") }
  let(:project_service) { Project.create(name: "postgres-service") }
  let(:timeline) { create_postgres_timeline(location_id: location.id) }
  let(:resource) { create_postgres_resource(project:, location_id: location.id) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "postgres-subnet", project:, location:,
      net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64"),
    )
  }
  let(:vm) { create_hosted_vm(project, private_subnet, "dummy-vm") }
  let(:location) {
    Location.create(
      name: "us-west-2", project:, display_name: "us-west-2", ui_name: "us-west-2",
      provider: "ubicloud", visible: true,
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(project_service.id)
    resource.update(flavor: PostgresResource::Flavor::STANDARD, cert_auth_users: [])
    MinioCluster.create(
      project_id: Config.postgres_service_project_id, location:, name: "pgminio",
      admin_user: "root", admin_password: "root",
    )
  end

  describe "#pg_stat_ch_extra_attributes" do
    it "renders instance_ubid, server_ubid, server_role, region, host_id" do
      value = postgres_server.pg_stat_ch_extra_attributes
      pairs = value.split(";").to_h { it.split(":", 2) }
      expect(pairs).to include(
        "instance_ubid" => resource.ubid,
        "server_ubid" => postgres_server.ubid,
        "server_role" => "primary",
        "region" => location.name,
      )
      expect(pairs).to have_key("host_id")
    end

    it "marks server_role as standby when timeline_access is fetch" do
      postgres_server.timeline_access = "fetch"
      expect(postgres_server.pg_stat_ch_extra_attributes).to include("server_role:standby")
    end

    it "uses aws_instance.instance_id for host_id on AWS-backed VMs" do
      aws_instance = instance_double(AwsInstance, instance_id: "i-0abcd1234ef567890")
      expect(postgres_server.vm).to receive(:aws_instance).and_return(aws_instance).at_least(:once)
      expect(postgres_server.pg_stat_ch_extra_attributes).to include("host_id:i-0abcd1234ef567890")
    end
  end

  describe "#configure_hash" do
    it "appends pg_stat_ch.extra_attributes to the base configs hash, single-quoted" do
      value = postgres_server.configure_hash[:configs]["pg_stat_ch.extra_attributes"]
      expect(value).to start_with("'").and end_with("'")
      expect(value[1..-2]).to eq(postgres_server.pg_stat_ch_extra_attributes)
    end

    it "appends pg_stat_ch.queue_capacity sized by vCPU tier" do
      value = postgres_server.configure_hash[:configs]["pg_stat_ch.queue_capacity"]
      expect(value).to eq(postgres_server.pg_stat_ch_queue_capacity.to_s)
    end

    it "appends pg_stat_ch.string_area_size sized by vCPU tier" do
      value = postgres_server.configure_hash[:configs]["pg_stat_ch.string_area_size"]
      expect(value).to eq(postgres_server.pg_stat_ch_string_area_size.to_s)
    end

    it "does not set pg_stat_ch.otel_log_queue_size (kept at compile default)" do
      expect(postgres_server.configure_hash[:configs]).not_to have_key("pg_stat_ch.otel_log_queue_size")
    end

    it "overrides the base configure_hash" do
      base_method = postgres_server.method(:configure_hash).super_method
      expect(base_method).not_to be_nil
      base_configs = base_method.call[:configs]
      expect(base_configs).not_to have_key("pg_stat_ch.extra_attributes")
    end
  end

  describe "#pg_stat_ch_queue_capacity" do
    {2 => 262_144, 4 => 524_288, 8 => 1_048_576, 16 => 2_097_152}.each do |vcpus, expected|
      it "returns #{expected} for a #{vcpus}-vCPU VM" do
        allow(postgres_server.vm).to receive(:vcpus).and_return(vcpus)
        expect(postgres_server.pg_stat_ch_queue_capacity).to eq(expected)
      end
    end
  end

  describe "#pg_stat_ch_string_area_size" do
    {2 => 64, 4 => 128, 8 => 256, 16 => 512}.each do |vcpus, expected|
      it "returns #{expected} MB for a #{vcpus}-vCPU VM" do
        allow(postgres_server.vm).to receive(:vcpus).and_return(vcpus)
        expect(postgres_server.pg_stat_ch_string_area_size).to eq(expected)
      end
    end
  end
end
