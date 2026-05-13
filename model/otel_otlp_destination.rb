# frozen_string_literal: true

require_relative "../model"

class OtelOtlpDestination < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_LOCATION
  many_to_one :location, key: :id
end

# Table: otel_otlp_destination
# Columns:
#  id                  | uuid | PRIMARY KEY
#  otlp_data_endpoint  | text | NOT NULL
#  otlp_arrow_endpoint | text | NOT NULL
#  logs_endpoint       | text | NOT NULL
#  metrics_endpoint    | text | NOT NULL
#  auth_audience       | text | NOT NULL
# Indexes:
#  otel_otlp_destination_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  otel_otlp_destination_id_fkey | (id) REFERENCES location(id) ON DELETE CASCADE
