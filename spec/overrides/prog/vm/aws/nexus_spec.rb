# frozen_string_literal: true

require "aws-sdk-ec2"
require "aws-sdk-iam"

RSpec.describe Prog::Vm::Aws::Nexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Vm::Aws::Nexus.new(st) }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
  }

  let(:location_credential) {
    loc = LocationCredentialAws.create_with_id(location, access_key: "test-access-key", secret_key: "test-secret-key")
    LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    loc
  }

  let(:storage_volumes) {
    [{encrypted: true, size_gib: 30}, {encrypted: true, size_gib: 3800}]
  }

  let(:vm) {
    location_credential
    Prog::Vm::Nexus.assemble_with_sshable(project.id,
      location_id: location.id, unix_user: "test-user-aws", boot_image: "ami-030c060f85668b37d",
      name: "testvm", size: "m6gd.large", arch: "arm64", storage_volumes:).subject
  }

  let(:st) { vm.strand }
  let(:client) { Aws::EC2::Client.new(stub_responses: true) }
  let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

  before do
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(client)
    allow(Aws::IAM::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(iam_client)
  end

  describe "#create_role_policy" do
    it "creates custom-build-s3-access policy when bucket names are configured" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(["my-custom-builds-bucket"])
      iam_client.stub_responses(:create_policy, {})

      expect(iam_client).to receive(:create_policy).with(hash_including(
        policy_name: "testvm-custom-build-s3-access",
        policy_document: a_string_including("my-custom-builds-bucket"),
      )).and_call_original

      expect(iam_client).to receive(:create_policy).with(hash_including(
        policy_name: "testvm-cw-agent-policy",
      )).and_call_original

      expect { nx.create_role_policy }.to hop("attach_role_policy")
    end

    it "skips custom-build-s3-access policy when bucket name is not configured" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(nil)
      iam_client.stub_responses(:create_policy, {})

      expect(iam_client).to receive(:create_policy).with(hash_including(
        policy_name: "testvm-cw-agent-policy",
      )).and_call_original

      expect(iam_client).not_to receive(:create_policy).with(hash_including(
        policy_name: "testvm-custom-build-s3-access",
      ))

      expect { nx.create_role_policy }.to hop("attach_role_policy")
    end

    it "ignores EntityAlreadyExists for custom-build-s3-access policy" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(["my-bucket"])
      iam_client.stub_responses(:create_policy, {})

      call_count = 0
      allow(iam_client).to receive(:create_policy).and_wrap_original do |m, params|
        call_count += 1
        if params[:policy_name] == "testvm-custom-build-s3-access"
          raise Aws::IAM::Errors::EntityAlreadyExists.new(nil, "EntityAlreadyExists")
        end
        m.call(params)
      end

      expect { nx.create_role_policy }.to hop("attach_role_policy")
      expect(call_count).to eq(2)
    end

    it "includes correct S3 actions and resources in policy document for multiple buckets" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(["bucket-a", "bucket-b"])
      iam_client.stub_responses(:create_policy, {})

      captured_doc = nil
      allow(iam_client).to receive(:create_policy) do |params|
        if params[:policy_name] == "testvm-custom-build-s3-access"
          captured_doc = JSON.parse(params[:policy_document])
        end
        iam_client.stub_data(:create_policy)
      end

      expect { nx.create_role_policy }.to hop("attach_role_policy")

      expect(captured_doc).not_to be_nil
      statement = captured_doc["Statement"].first
      expect(statement["Sid"]).to eq("Statement1")
      expect(statement["Effect"]).to eq("Allow")
      expect(statement["Action"]).to contain_exactly(
        "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket",
      )
      expect(statement["Resource"]).to contain_exactly(
        "arn:aws:s3:::bucket-a",
        "arn:aws:s3:::bucket-a/*",
        "arn:aws:s3:::bucket-b",
        "arn:aws:s3:::bucket-b/*",
      )
    end
  end

  describe "#attach_role_policy" do
    it "attaches custom-build-s3-access policy when configured" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(["my-bucket"])
      iam_client.stub_responses(:attach_role_policy, {})
      iam_client.stub_responses(:list_policies,
        policies: [
          {policy_name: "testvm-cw-agent-policy", arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"},
          {policy_name: "testvm-custom-build-s3-access", arn: "arn:aws:iam::aws:policy/testvm-custom-build-s3-access"},
        ])

      expect(iam_client).to receive(:attach_role_policy).with({
        role_name: "testvm",
        policy_arn: "arn:aws:iam::aws:policy/testvm-custom-build-s3-access",
      }).and_call_original

      expect(iam_client).to receive(:attach_role_policy).with({
        role_name: "testvm",
        policy_arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy",
      }).and_call_original

      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end

    it "skips custom-build-s3-access when not configured" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(nil)
      iam_client.stub_responses(:attach_role_policy, {})
      iam_client.stub_responses(:list_policies,
        policies: [{policy_name: "testvm-cw-agent-policy", arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"}])

      expect(iam_client).not_to receive(:attach_role_policy).with(hash_including(
        policy_arn: a_string_including("custom-build-s3-access"),
      ))

      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end

    it "skips attach when policy not found in IAM" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(["my-bucket"])
      iam_client.stub_responses(:attach_role_policy, {})
      iam_client.stub_responses(:list_policies,
        policies: [{policy_name: "testvm-cw-agent-policy", arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"}])

      expect(iam_client).not_to receive(:attach_role_policy).with(hash_including(
        policy_arn: a_string_including("custom-build-s3-access"),
      ))

      expect { nx.attach_role_policy }.to hop("create_instance_profile")
    end
  end

  describe "#cleanup_roles" do
    before do
      iam_client.stub_responses(:remove_role_from_instance_profile, {})
      iam_client.stub_responses(:delete_instance_profile, {})
      iam_client.stub_responses(:delete_policy, {})
      iam_client.stub_responses(:delete_role, {})
      iam_client.stub_responses(:detach_role_policy, {})
      iam_client.stub_responses(:list_attached_role_policies, attached_policies: [])
    end

    it "detaches and deletes custom-build-s3-access policy during cleanup" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(["my-bucket"])
      iam_client.stub_responses(:list_policies, policies: [
        {policy_name: "testvm-cw-agent-policy", arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"},
        {policy_name: "testvm-custom-build-s3-access", arn: "arn:aws:iam::aws:policy/testvm-custom-build-s3-access"},
      ])

      detach_calls = []
      delete_calls = []
      allow(iam_client).to receive(:detach_role_policy).and_wrap_original do |m, params|
        detach_calls << params[:policy_arn]
        m.call(params)
      end
      allow(iam_client).to receive(:delete_policy).and_wrap_original do |m, params|
        delete_calls << params[:policy_arn]
        m.call(params)
      end

      expect { nx.cleanup_roles }.to exit({"msg" => "vm destroyed"})
      expect(detach_calls).to include("arn:aws:iam::aws:policy/testvm-custom-build-s3-access")
      expect(delete_calls).to include("arn:aws:iam::aws:policy/testvm-custom-build-s3-access")
    end

    it "cleans up custom-build-s3-access even when config is unset" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(nil)
      iam_client.stub_responses(:list_policies, policies: [
        {policy_name: "testvm-cw-agent-policy", arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"},
        {policy_name: "testvm-custom-build-s3-access", arn: "arn:aws:iam::aws:policy/testvm-custom-build-s3-access"},
      ])

      detach_calls = []
      delete_calls = []
      allow(iam_client).to receive(:detach_role_policy).and_wrap_original do |m, params|
        detach_calls << params[:policy_arn]
        m.call(params)
      end
      allow(iam_client).to receive(:delete_policy).and_wrap_original do |m, params|
        delete_calls << params[:policy_arn]
        m.call(params)
      end

      expect { nx.cleanup_roles }.to exit({"msg" => "vm destroyed"})
      expect(detach_calls).to include("arn:aws:iam::aws:policy/testvm-custom-build-s3-access")
      expect(delete_calls).to include("arn:aws:iam::aws:policy/testvm-custom-build-s3-access")
    end

    it "skips cleanup when custom-build-s3-access policy not found in IAM" do
      allow(Config).to receive(:aws_s3_custom_builds_bucket_names).and_return(nil)
      iam_client.stub_responses(:list_policies, policies: [
        {policy_name: "testvm-cw-agent-policy", arn: "arn:aws:iam::aws:policy/testvm-cw-agent-policy"},
      ])

      expect(iam_client).not_to receive(:detach_role_policy).with(hash_including(
        policy_arn: a_string_including("custom-build-s3-access"),
      ))

      expect { nx.cleanup_roles }.to exit({"msg" => "vm destroyed"})
    end
  end

  describe "#custom_build_s3_policy" do
    it "finds policy on first page" do
      iam_client.stub_responses(:list_policies, policies: [{policy_name: "testvm-custom-build-s3-access", arn: "arn:aws:iam::aws:policy/testvm-custom-build-s3-access"}], is_truncated: false)
      policy = nx.custom_build_s3_policy
      expect(policy).not_to be_nil
      expect(policy.policy_name).to eq("testvm-custom-build-s3-access")
    end

    it "paginates through multiple pages to find policy" do
      first_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-1", arn: "arn:aws:iam::aws:policy/other-policy-1"}],
        is_truncated: true,
        marker: "next-page-marker",
      })

      second_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "testvm-custom-build-s3-access", arn: "arn:aws:iam::aws:policy/testvm-custom-build-s3-access"}],
        is_truncated: false,
      })

      iam_client.stub_responses(:list_policies, first_response, second_response)

      policy = nx.custom_build_s3_policy
      expect(policy).not_to be_nil
      expect(policy.policy_name).to eq("testvm-custom-build-s3-access")
    end

    it "returns nil when policy not found after all pages" do
      first_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-1", arn: "arn:aws:iam::aws:policy/other-policy-1"}],
        is_truncated: true,
        marker: "next-page-marker",
      })

      second_response = iam_client.stub_data(:list_policies, {
        policies: [{policy_name: "other-policy-2", arn: "arn:aws:iam::aws:policy/other-policy-2"}],
        is_truncated: false,
      })

      iam_client.stub_responses(:list_policies, first_response, second_response)

      policy = nx.custom_build_s3_policy
      expect(policy).to be_nil
      expect(iam_client.api_requests).to include(
        a_hash_including(operation_name: :list_policies, params: a_hash_including(scope: "Local", max_items: 100, marker: nil)),
        a_hash_including(operation_name: :list_policies, params: a_hash_including(scope: "Local", max_items: 100, marker: "next-page-marker")),
      )
    end
  end

  describe "#custom_build_s3_policy_name" do
    it "returns the correct policy name" do
      expect(nx.custom_build_s3_policy_name).to eq("testvm-custom-build-s3-access")
    end
  end
end
