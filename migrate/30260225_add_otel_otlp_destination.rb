# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:otel_otlp_destination) do
      foreign_key :id, :location, type: :uuid, primary_key: true, on_delete: :cascade
      column :otlp_data_endpoint, :text, null: false
      column :otlp_arrow_endpoint, :text, null: false
      column :logs_endpoint, :text, null: false
      column :metrics_endpoint, :text, null: false
      column :auth_audience, :text, null: false
    end
  end

  down do
    drop_table(:otel_otlp_destination)
  end
end
