# frozen_string_literal: true

require_relative "../../../prog/postgres/spec_helper"

RSpec.describe Prog::Postgres::PostgresTimelineNexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Postgres::PostgresTimelineNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_timeline) { create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID) }
  let(:st) { postgres_timeline.strand }

  describe "#take_backup" do
    before { st.update(label: "take_backup") }

    it "clears take_backup_for_converge and hops to wait when the leader has vanished (e.g. mid billing-deactivate destroy)" do
      postgres_timeline.incr_take_backup_for_converge
      allow(nx.postgres_timeline).to receive(:leader).and_return(nil)

      expect { nx.take_backup }.to hop("wait")
      expect(postgres_timeline.reload.take_backup_for_converge_set?).to be(false)
    end

    it "prepends the base #take_backup (super_method present)" do
      expect(nx.method(:take_backup).super_method).not_to be_nil
    end
  end
end
