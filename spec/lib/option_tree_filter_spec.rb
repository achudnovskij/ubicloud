# frozen_string_literal: true

<<<<<<< HEAD
require "rspec"
require_relative "../../lib/option_tree_filter"

RSpec.describe OptionTreeFilter do
  describe ".filter" do
    context "when filtering by provider" do
      it "returns only entries from the specified provider" do
        results = described_class.filter(provider: "aws")
        expect(results).to all(include(provider: "aws"))
        expect(results).not_to be_empty
      end

      it "returns empty when provider does not exist" do
        results = described_class.filter(provider: "nonexistent-provider")
        expect(results).to be_empty
      end
    end

    context "when filtering by location" do
      it "returns only entries from the specified location" do
        results = described_class.filter(provider: "aws", location: "us-east-1")
        expect(results).to all(include(location: "us-east-1"))
        expect(results).not_to be_empty
      end

      it "returns empty when location does not exist" do
        results = described_class.filter(provider: "aws", location: "nonexistent-location")
        expect(results).to be_empty
      end
    end

    context "when filtering by family" do
      it "returns only entries from the specified family" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd")
        expect(results).to all(include(family: "m6gd"))
        expect(results).not_to be_empty
      end

      it "returns empty when family does not exist" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "nonexistent-family")
        expect(results).to be_empty
      end
    end

    context "when filtering by size" do
      it "returns only entries with the specified size" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd", size: "m6gd.large")
        expect(results.size).to eq(1)
        expect(results.first).to include(size: "m6gd.large")
      end

      it "returns empty when size does not exist" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd", size: "nonexistent-size")
        expect(results).to be_empty
      end
    end

    context "when combining filters" do
      it "filters by provider, location, family, and size" do
        results = described_class.filter(provider: "aws", location: "us-east-1", family: "m6gd", size: "m6gd.large")
        expect(results.size).to eq(1)
        expect(results.first).to include(provider: "aws", location: "us-east-1", family: "m6gd", size: "m6gd.large")
      end
=======
require_relative "../spec_helper"

RSpec.describe OptionTreeFilter do
  describe ".filter" do
    it "returns all entries with no filters" do
      results = described_class.filter
      expect(results).not_to be_empty
      expect(results.first).to include(:provider, :location, :family, :size)
    end

    it "filters by provider" do
      results = described_class.filter(provider: "aws")
      expect(results).to all(include(provider: "aws"))
      expect(results).not_to be_empty
    end

    it "returns empty for non-matching provider" do
      expect(described_class.filter(provider: "nonexistent")).to be_empty
    end

    it "filters by location" do
      results = described_class.filter(provider: "aws", location: "ap-northeast-1")
      expect(results).to all(include(location: "ap-northeast-1"))
      expect(results).not_to be_empty
    end

    it "returns empty for non-matching location" do
      expect(described_class.filter(provider: "aws", location: "nonexistent")).to be_empty
    end

    it "filters by family" do
      results = described_class.filter(provider: "aws", location: "ap-northeast-1", family: "c6gd")
      expect(results).to all(include(family: "c6gd"))
      expect(results).not_to be_empty
    end

    it "returns empty for non-matching family" do
      expect(described_class.filter(provider: "aws", location: "ap-northeast-1", family: "nonexistent")).to be_empty
    end

    it "filters by size" do
      results = described_class.filter(provider: "aws", location: "ap-northeast-1", family: "c6gd", size: "c6gd.medium")
      expect(results.length).to eq(1)
      expect(results.first).to include(size: "c6gd.medium")
    end

    it "returns empty for non-matching size" do
      expect(described_class.filter(provider: "aws", location: "ap-northeast-1", family: "c6gd", size: "nonexistent")).to be_empty
    end
  end

  describe ".filter_data" do
    it "returns empty when data is nil" do
      expect(described_class.filter_data(nil)).to be_empty
    end

    it "returns empty when data has no providers" do
      expect(described_class.filter_data({})).to be_empty
    end

    it "skips providers with no locations" do
      data = {"providers" => {"aws" => {}}}
      expect(described_class.filter_data(data)).to be_empty
    end

    it "skips locations with no families" do
      data = {"providers" => {"aws" => {"locations" => {"us-east-1" => {}}}}}
      expect(described_class.filter_data(data)).to be_empty
    end

    it "skips families with no sizes" do
      data = {"providers" => {"aws" => {"locations" => {"us-east-1" => {"families" => {"m8gd" => {}}}}}}}
      expect(described_class.filter_data(data)).to be_empty
    end
  end

  describe ".data" do
    it "returns loaded YAML data" do
      expect(described_class.data).to be_a(Hash)
      expect(described_class.data).to include("providers")
>>>>>>> bb92b3291ffd8a4fd226fec716f350dca8de4623
    end
  end
end
