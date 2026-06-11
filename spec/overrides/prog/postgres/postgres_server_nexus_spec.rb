# frozen_string_literal: true

require "uri"
require "open3"
require_relative "../../../prog/postgres/spec_helper"

RSpec.describe Prog::Postgres::PostgresServerNexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Postgres::PostgresServerNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe "#run_post_installation_script" do
    it "creates pg_stat_ch for standard flavor primary when post-installation succeeds" do
      allow(sshable).to receive(:d_check).with("post_installation_script").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with(
        "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'",
        hash_including(stdin: /CREATE EXTENSION IF NOT EXISTS pg_stat_ch/),
      ).and_return("")
      expect { nx.run_post_installation_script }.to hop("wait")
    end

    it "does not create pg_stat_ch for non-standard flavors" do
      # LANTERN rather than PARADEDB so super's paradedb_and_primary? branch
      # does not fire and try to run its own CREATE EXTENSION DDL.
      postgres_server.resource.update(flavor: PostgresResource::Flavor::LANTERN)
      allow(sshable).to receive(:d_check).with("post_installation_script").and_return("Succeeded")
      expect(sshable).not_to receive(:_cmd).with(
        anything,
        hash_including(stdin: /CREATE EXTENSION IF NOT EXISTS pg_stat_ch/),
      )
      expect { nx.run_post_installation_script }.to hop("wait")
    end

    it "does not create pg_stat_ch on standby servers" do
      postgres_server.update(timeline_access: "fetch", synchronization_status: "ready")
      allow(sshable).to receive(:d_check).with("post_installation_script").and_return("Succeeded")
      expect(sshable).not_to receive(:_cmd).with(
        anything,
        hash_including(stdin: /CREATE EXTENSION IF NOT EXISTS pg_stat_ch/),
      )
      expect { nx.run_post_installation_script }.to hop("wait")
    end

    it "does not run CREATE EXTENSION when post-installation has not finished yet" do
      allow(sshable).to receive(:d_check).with("post_installation_script").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("post_installation_script", "sudo", "postgres/bin/post-installation-script")
      expect(sshable).not_to receive(:_cmd).with(
        anything,
        hash_including(stdin: /CREATE EXTENSION IF NOT EXISTS pg_stat_ch/),
      )
      expect { nx.run_post_installation_script }.to nap(1)
    end
  end

  describe "#setup_otel_collector" do
    it "writes otel config, enables and reloads otelcol-contrib, then hops to bootstrap_rhizome" do
      OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config.yaml", anything, user: "otelcol")
      expect(sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now otelcol-contrib")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")
      expect { nx.setup_otel_collector }.to hop("bootstrap_rhizome")
    end
  end

  describe "#setup_otel" do
    before do
      allow(sshable).to receive(:write_file).with("/home/otelcol/otel-config.yaml", anything, user: "otelcol")
      allow(sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))
    end

    it "writes the SKU memory as a node exporter prom file" do
      OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
      expect(sshable).to receive(:write_file).with(
        "/var/lib/node_exporter/vm_sku.prom",
        match(/node_memory_sku_total_bytes #{postgres_server.sku_memory_bytes}/),
      )

      nx.setup_otel
    end

    it "writes otelcol config with metadata and export endpoint" do
      OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
        expect(content).to include("exporters:")
        expect(content).to include("endpoint: https://otel.example.com:4317")
        expect(content).to include("processors:")
        expect(content).to include("ubi.postgres_server_ubid")
        expect(content).to include("ubi.postgres_resource_ubid")
        expect(content).to include("ubi.postgres_resource_uuid")
        expect(content).to include("ubi.postgres_server_role")
        expect(content).to include("ubi.postgres_resource_read_replica")
        expect(content).to include("ubi.postgres_resource_ha_type")
        expect(content).to include("ubi.postgres_resource_target_standby_count")
        expect(content).to include("ubi.postgres_resource_target_server_count")
      end

      nx.setup_otel
    end

    it "writes otelcol config with empty endpoint when not configured" do
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
        expect(content).to include("exporters:")
        expect(content).to include("endpoint:")
        expect(content).to include("processors:")
        expect(content).to include("ubi.postgres_server_ubid")
        expect(content).to include("ubi.postgres_resource_ubid")
        expect(content).to include("ubi.postgres_resource_uuid")
        expect(content).to include("ubi.postgres_resource_ha_type")
        expect(content).to include("ubi.postgres_resource_target_standby_count")
        expect(content).to include("ubi.postgres_resource_target_server_count")
      end

      nx.setup_otel
    end

    it "writes otelcol config with dynamic tag attributes" do
      OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

      postgres_server.resource.update(tags: [
        {"key" => "chc_environment", "value" => "production"},
        {"key" => "chc_team.name", "value" => "backend"},
        {"key" => "chc_region-id", "value" => "us-west-2"},
        {"key" => "owner", "value" => "should-be-filtered"},
      ])

      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
        expect(content).to include("ubi.postgres_resource_tags_label_chc_environment")
        expect(content).to include("value: 'production'")
        expect(content).to include("ubi.postgres_resource_tags_label_chc_team_name")
        expect(content).to include("value: 'backend'")
        expect(content).to include("ubi.postgres_resource_tags_label_chc_region_id")
        expect(content).to include("value: 'us-west-2'")
        expect(content).not_to include("ubi.postgres_resource_tags_label_chc_team.name")
        expect(content).not_to include("ubi.postgres_resource_tags_label_chc_region-id")
        expect(content).not_to include("ubi.postgres_resource_tags_label_owner")
        expect(content).not_to include("should-be-filtered")

        parsed = YAML.safe_load(content)
        attrs = parsed.dig("processors", "resource/ubiMetadata", "attributes")
        tag_keys = attrs.map { |a| a["key"] }
        expect(tag_keys).to include("ubi.postgres_resource_tags_label_chc_environment")
        expect(tag_keys).to include("ubi.postgres_resource_tags_label_chc_team_name")
        expect(tag_keys).to include("ubi.postgres_resource_tags_label_chc_region_id")
        expect(tag_keys).not_to include("ubi.postgres_resource_tags_label_owner")
      end

      nx.setup_otel
    end

    context "with OIDC authentication enabled" do
      let(:oidc_provider) {
        OidcProvider.create(
          display_name: "test-provider",
          url: "https://test-auth.example.com/",
          authorization_endpoint: "/authorize",
          token_endpoint: "/oauth/token",
          userinfo_endpoint: "/userinfo",
          jwks_uri: "https://test-auth.example.com/.well-known/jwks.json",
          client_id: "test-client-id",
          client_secret: "test-client-secret",
        )
      }

      before do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(oidc_provider.id)
      end

      it "includes auth configuration in otel config" do
        OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).to include("auth:")
          expect(content).to include("authenticator: bearertokenauth/otlp-export")
        end
        expect(nx).to receive(:write_otel_token)

        nx.setup_otel
      end

      it "includes standby role in otel config for non-representative server" do
        server
        standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
        standby_nx = Prog::Postgres::PostgresServerNexus.new(standby.strand)
        standby_sshable = standby_nx.postgres_server.vm.sshable
        OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).to include("value: 'standby'")
        end
        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otel-config.yaml", anything, user: "otelcol")
        expect(standby_sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))
        expect(standby_nx).to receive(:write_otel_token)

        standby_nx.setup_otel
      end

      it "always calls write_otel_token" do
        OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
        expect(nx).to receive(:write_otel_token)

        nx.setup_otel
      end

      it "does not include auth configuration when OIDC provider is not configured" do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)
        OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).not_to include("auth:")
          expect(content).not_to include("authenticator: bearertokenauth/otlp-export")
        end

        nx.setup_otel
      end
    end

    it "generates a valid otelcol-contrib config", no_otel_binary: false do
      OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")

      configs = {}
      allow(sshable).to receive(:write_file) do |path, content, **|
        configs[path] = content
      end
      expect(nx).to receive(:write_otel_token)

      nx.setup_otel

      Dir.mktmpdir("otel-config-validate") do |tmpdir|
        configs.each do |path, content|
          filename = File.basename(path)
          File.write(File.join(tmpdir, filename), content)
        end

        config_flags = ["otel-config.yaml", "otel-config-override.yaml"]
          .select { |f| File.exist?(File.join(tmpdir, f)) }
          .map { |f| "--config=#{File.join(tmpdir, f)}" }
          .join(" ")

        stdout, stderr, status = Open3.capture3("otelcol-contrib validate #{config_flags}")
        expect(status.success?).to be(true), "otelcol-contrib validate failed:\nstdout: #{stdout}\nstderr: #{stderr}"
      end
    end
  end

  describe "#write_otel_token" do
    let(:oidc_provider) {
      OidcProvider.create(
        display_name: "test-provider",
        url: "https://test-auth.example.com/",
        authorization_endpoint: "/authorize",
        token_endpoint: "/oauth/token",
        userinfo_endpoint: "/userinfo",
        jwks_uri: "https://test-auth.example.com/.well-known/jwks.json",
        client_id: "test-client-id",
        client_secret: "test-client-secret",
      )
    }

    before do
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(oidc_provider.id)
      OtelOtlpDestination.create_with_id(postgres_server.resource.location, otlp_data_endpoint: "https://otel.example.com:4317", otlp_arrow_endpoint: "https://otel.example.com:4317", logs_endpoint: "https://otel.example.com:4317", metrics_endpoint: "https://otel.example.com:4317", auth_audience: "https://otel.example.com:4317")
    end

    it "returns early when OIDC provider is not configured" do
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)

      expect(Excon).not_to receive(:post)
      nx.write_otel_token
    end

    it "makes token request with correct parameters" do
      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .with(
          body: hash_including(
            "grant_type" => "client_credentials",
            "audience" => "https://otel.example.com:4317",
          ),
        )
        .to_return(
          status: 200,
          body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600}),
        )

      expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

      nx.write_otel_token
    end

    it "reloads otelcol-contrib after writing the token" do
      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .to_return(
          status: 200,
          body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600}),
        )

      expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol").ordered
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib").ordered

      nx.write_otel_token
    end

    context "with additional metadata field configured" do
      before do
        allow(Config).to receive(:postgres_otel_otlp_export_additional_metadata_field).and_return("aws_client_metadata")
      end

      it "includes metadata in token request" do
        stub_request(:post, "https://test-auth.example.com/oauth/token")
          .with(
            body: hash_including("aws_client_metadata"),
          )
          .to_return(
            status: 200,
            body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600}),
          )

        expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
        expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

        nx.write_otel_token
      end

      it "includes correct metadata with server ubid, resource ubid, and role" do
        metadata_json = nil

        stub_request(:post, "https://test-auth.example.com/oauth/token")
          .with { |request|
            body_params = URI.decode_www_form(request.body).to_h
            metadata_json = JSON.parse(body_params["aws_client_metadata"]) if body_params["aws_client_metadata"]
            true
          }
          .to_return(
            status: 200,
            body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600}),
          )

        expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
        expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

        nx.write_otel_token

        expect(metadata_json).not_to be_nil
        expect(metadata_json["postgres_server_id"]).to eq(postgres_server.ubid)
        expect(metadata_json["postgres_resource_id"]).to eq(postgres_server.resource.ubid)
        expect(metadata_json["postgres_resource_uuid"]).to eq(postgres_server.resource.id)
        expect(metadata_json["postgres_server_role"]).to eq("primary")
      end

      it "includes standby role when server is not representative" do
        standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
        standby_nx = Prog::Postgres::PostgresServerNexus.new(standby.strand)
        standby_sshable = standby_nx.postgres_server.vm.sshable

        metadata_json = nil

        stub_request(:post, "https://test-auth.example.com/oauth/token")
          .with { |request|
            body_params = URI.decode_www_form(request.body).to_h
            metadata_json = JSON.parse(body_params["aws_client_metadata"]) if body_params["aws_client_metadata"]
            true
          }
          .to_return(
            status: 200,
            body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600}),
          )

        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
        expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

        standby_nx.write_otel_token

        expect(metadata_json).not_to be_nil
        expect(metadata_json["postgres_server_role"]).to eq("standby")
      end
    end

    it "raises error when OIDC provider ID is configured but provider does not exist" do
      non_existent_uuid = SecureRandom.uuid
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(non_existent_uuid)

      expect {
        nx.write_otel_token
      }.to raise_error(/does not correspond to an existing OidcProvider/)
    end

    it "raises error when OAuth response is missing access_token" do
      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .to_return(
          status: 200,
          body: JSON.generate({"token_type" => "Bearer", "expires_in" => 3600}),
        )

      expect {
        nx.write_otel_token
      }.to raise_error(/missing access_token/)
    end

    it "makes token request without audience when endpoint is not set" do
      postgres_server.resource.location.otel_otlp_destination.destroy

      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .with { |request|
          params = URI.decode_www_form(request.body).to_h
          params["grant_type"] == "client_credentials" && !params.key?("audience")
        }
        .to_return(
          status: 200,
          body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer"}),
        )

      expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

      nx.write_otel_token
    end
  end

  describe "#otel_token_needs_refresh?" do
    it "returns false when OIDC provider is not configured" do
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)
      expect(nx.otel_token_needs_refresh?).to be false
    end

    context "when OIDC provider is configured" do
      before do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(SecureRandom.uuid)
      end

      it "returns true and does not cache when token file is missing or empty" do
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return("")
        expect(nx.otel_token_needs_refresh?).to be true
        expect(st.stack.first).not_to have_key("otel_token_jwt")
      end

      it "returns true and skips cache when JWT is missing iat" do
        now = Time.now.to_i
        token = JWT.encode({"exp" => now + 3600}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be true
        expect(st.stack.first).not_to have_key("otel_token_jwt")
      end

      it "returns true and skips cache when JWT is missing exp" do
        now = Time.now.to_i
        token = JWT.encode({"iat" => now}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be true
        expect(st.stack.first).not_to have_key("otel_token_jwt")
      end

      it "returns false when token is still fresh" do
        now = Time.now.to_i
        token = JWT.encode({"iat" => now, "exp" => now + 3600}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be false
        expect(st.stack.first["otel_token_jwt"]).to eq({"iat" => now, "exp" => now + 3600})
      end

      it "returns true when 2/3 of token validity has passed" do
        now = Time.now.to_i
        iat = now - 3000
        exp = now - 3000 + 3600
        token = JWT.encode({"iat" => iat, "exp" => exp}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be true
        expect(st.stack.first["otel_token_jwt"]).to eq({"iat" => iat, "exp" => exp})
      end

      it "emits Clog and returns true on JWT decode error, leaving cache untouched" do
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return("not-a-valid-jwt")
        expect(Clog).to receive(:emit).with("OTel token JWT decode failed", hash_including(otel_token_jwt_decode_error: hash_including(:error)))
        expect(nx.otel_token_needs_refresh?).to be true
        expect(st.stack.first).not_to have_key("otel_token_jwt")
      end

      it "returns false without SSH when cache shows token is within 2/3 lifetime" do
        now = Time.now.to_i
        st.stack.first["otel_token_jwt"] = {"iat" => now - 100, "exp" => now + 3500}
        expect(sshable).not_to receive(:_cmd)
        expect(nx.otel_token_needs_refresh?).to be false
      end

      it "refreshes cache when cached iat/exp is past 2/3 and SSH finds a newer token" do
        now = Time.now.to_i
        st.stack.first["otel_token_jwt"] = {"iat" => now - 3500, "exp" => now - 100}
        new_token = JWT.encode({"iat" => now, "exp" => now + 3600}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(new_token)
        expect(nx.otel_token_needs_refresh?).to be false
        expect(st.stack.first["otel_token_jwt"]).to eq({"iat" => now, "exp" => now + 3600})
      end

      it "does not write otel_token_jwt when SSH returns iat/exp identical to the cache" do
        now = Time.now.to_i
        stale = {"iat" => now - 3500, "exp" => now - 100}
        st.stack.first["otel_token_jwt"] = stale
        stale_token = JWT.encode(stale, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(stale_token)
        expect(nx).not_to receive(:otel_token_jwt=)
        expect(nx.otel_token_needs_refresh?).to be true
      end
    end
  end

  describe "#postgres_exporter_queries_yaml" do
    # Verify the merge contract by stubbing override content per case rather than
    # re-running `base.merge(override).compact` against the live override file
    # (which would tautologically agree with the implementation). The base file
    # is the real OSS file; override content is controlled per example.
    before do
      allow(YAML).to receive(:safe_load_file).and_call_original
    end

    it "adds override-only top-level keys to the result" do
      allow(YAML).to receive(:safe_load_file).with("override/config/postgres_exporter_queries.yml")
        .and_return({"override_only_query" => {"query" => "SELECT 1", "metrics" => []}})

      parsed = YAML.safe_load(nx.send(:postgres_exporter_queries_yaml))

      expect(parsed["override_only_query"]).to eq({"query" => "SELECT 1", "metrics" => []})
      expect(parsed).to have_key("pg_stat_activity")  # base preserved
    end

    it "replaces the base block when the override reuses a base key" do
      allow(YAML).to receive(:safe_load_file).with("override/config/postgres_exporter_queries.yml")
        .and_return({"pg_stat_activity" => {"query" => "FORK SQL", "metrics" => [{"x" => {"usage" => "GAUGE"}}]}})

      parsed = YAML.safe_load(nx.send(:postgres_exporter_queries_yaml))

      expect(parsed["pg_stat_activity"]).to eq({"query" => "FORK SQL", "metrics" => [{"x" => {"usage" => "GAUGE"}}]})
    end

    it "drops a base key when the override sets that key to nil" do
      allow(YAML).to receive(:safe_load_file).with("override/config/postgres_exporter_queries.yml")
        .and_return({"pg_stat_activity" => nil})

      parsed = YAML.safe_load(nx.send(:postgres_exporter_queries_yaml))

      expect(parsed).not_to have_key("pg_stat_activity")
      expect(parsed).to have_key("pg_stat_database")  # other base keys untouched
    end

    it "treats a nil/empty override file as no deltas (result equals base)" do
      allow(YAML).to receive(:safe_load_file).with("override/config/postgres_exporter_queries.yml")
        .and_return(nil)

      parsed = YAML.safe_load(nx.send(:postgres_exporter_queries_yaml))

      expect(parsed).to eq(YAML.safe_load_file("config/postgres_exporter_queries.yml"))
    end
  end

  describe "#configure_metrics override end-to-end" do
    let(:metrics_config) { {interval: "30s", endpoints: ["https://localhost:9100/metrics"], metrics_dir: "/home/ubi/postgres/metrics"} }

    it "writes content carrying both base and override queries to the canonical postgres_exporter queries path" do
      nx.incr_initial_provisioning
      allow(Config).to receive_messages(postgres_otel_otlp_export_enabled: false, postgres_otel_otlp_export_jwt_oidc_provider_id: nil)
      allow(nx.postgres_server).to receive(:metrics_config).and_return(metrics_config)
      allow(nx.postgres_server.resource).to receive(:metric_destinations).and_return([])
      allow(sshable).to receive(:_cmd)

      # `pg_replica` is from override/config/postgres_exporter_queries.yml;
      # `pg_stat_activity` is from config/postgres_exporter_queries.yml. Both being
      # present in the tee'd content proves the override file was read and merged
      # on top of the base before write_file ran.
      expect(sshable).to receive(:_cmd).with(
        "sudo tee /usr/local/share/postgresql/postgres_exporter_queries.yaml > /dev/null",
        stdin: a_string_including("pg_replica", "pg_stat_activity"),
      )

      expect { nx.configure_metrics }.to hop("configure_logs")
    end
  end

  describe "#configure_logs" do
    before do
      allow(sshable).to receive(:d_check).with("configure_logs").and_return("Succeeded")
      allow(sshable).to receive(:d_clean).with("configure_logs")
    end

    it "emits a Clog, stamps the daemonizer with a no-op, and hops via super to wait" do
      expect(Clog).to receive(:emit).with("configure_logs skipped; logs handled by configure_metrics")
      expect(sshable).to receive(:d_run).with("configure_logs", "true")
      expect(sshable).not_to receive(:d_run).with("configure_logs", "/home/ubi/postgres/bin/configure-logs", anything)
      expect(sshable).to receive(:d_clean).with("configure_logs")
      expect { nx.configure_logs }.to hop("wait")
    end

    it "routes through the initial-provisioning hop chain in super" do
      nx.incr_initial_provisioning
      expect(Clog).to receive(:emit).with("configure_logs skipped; logs handled by configure_metrics")
      expect(sshable).to receive(:d_run).with("configure_logs", "true")
      expect { nx.configure_logs }.to hop("setup_hugepages")
    end
  end
end
