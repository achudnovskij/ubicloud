# frozen_string_literal: true

require "yaml"

# rubocop:disable RSpec/DescribeClass
# There is no class in this case; the spec verifies a static config file.
RSpec.describe "override/config/postgres_exporter_queries.yml" do
  # rubocop:enable RSpec/DescribeClass
  it "parses as YAML" do
    expect { YAML.safe_load_file("override/config/postgres_exporter_queries.yml") }.not_to raise_error
  end

  it "parses to a Hash mapping query names to query definitions (use `{}` for an explicit no-op placeholder)" do
    parsed = YAML.safe_load_file("override/config/postgres_exporter_queries.yml")
    expect(parsed).to be_a(Hash)
  end
end
