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

  describe "#setup_otel_collector" do
    it "writes otel config, enables and reloads otelcol-contrib, then hops to bootstrap_rhizome" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")
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
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
      expect(sshable).to receive(:write_file).with(
        "/var/lib/node_exporter/vm_sku.prom",
        match(/node_memory_sku_total_bytes #{postgres_server.sku_memory_bytes}/),
      )

      nx.setup_otel
    end

    it "writes otelcol config with metadata and export endpoint" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

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
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

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
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

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
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).to include("value: 'standby'")
        end
        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otel-config.yaml", anything, user: "otelcol")
        expect(standby_sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))
        expect(standby_nx).to receive(:write_otel_token)

        standby_nx.setup_otel
      end

      it "always calls write_otel_token" do
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
        expect(nx).to receive(:write_otel_token)

        nx.setup_otel
      end

      it "does not include auth configuration when OIDC provider is not configured" do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).not_to include("auth:")
          expect(content).not_to include("authenticator: bearertokenauth/otlp-export")
        end

        nx.setup_otel
      end
    end

    it "generates a valid otelcol-contrib config", no_otel_binary: false do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

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
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")
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
      postgres_server.resource.location.update(otel_otlp_export_endpoint: nil)

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

      it "does not call update_stack when SSH returns iat/exp identical to the cache" do
        now = Time.now.to_i
        stale = {"iat" => now - 3500, "exp" => now - 100}
        st.stack.first["otel_token_jwt"] = stale
        stale_token = JWT.encode(stale, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(stale_token)
        expect(nx).not_to receive(:update_stack)
        expect(nx.otel_token_needs_refresh?).to be true
      end
    end
  end
end
