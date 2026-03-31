# frozen_string_literal: true

RSpec.describe Dispatch::Adapter::Base do
  subject(:base) { described_class.new }

  describe "#chat" do
    it "raises NotImplementedError" do
      expect { base.chat([]) }.to raise_error(NotImplementedError, /chat must be implemented/)
    end
  end

  describe "#model_name" do
    it "raises NotImplementedError" do
      expect { base.model_name }.to raise_error(NotImplementedError, /model_name must be implemented/)
    end
  end

  describe "#count_tokens" do
    it "returns -1" do
      expect(base.count_tokens([])).to eq(-1)
    end
  end

  describe "#list_models" do
    it "raises NotImplementedError" do
      expect { base.list_models }.to raise_error(NotImplementedError, /list_models must be implemented/)
    end
  end

  describe "#provider_name" do
    it "returns the class name" do
      expect(base.provider_name).to eq("Dispatch::Adapter::Base")
    end
  end

  describe "#max_context_tokens" do
    it "returns nil" do
      expect(base.max_context_tokens).to be_nil
    end
  end
end
