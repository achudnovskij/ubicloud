# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "OtelOtlpDestination" do
  include AdminModelSpecHelper

  before do
    @instance = create_otel_otlp_destination
    admin_account_setup_and_login
  end

  it "displays the OtelOtlpDestination instance page correctly" do
    click_link "OtelOtlpDestination"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - OtelOtlpDestination"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - OtelOtlpDestination #{@instance.ubid}"
  end
end
