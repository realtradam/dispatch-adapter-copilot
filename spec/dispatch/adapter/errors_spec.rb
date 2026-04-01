# frozen_string_literal: true

RSpec.describe Dispatch::Adapter::Error do
  it "carries message, status_code, and provider" do
    error = described_class.new("test error", status_code: 500, provider: "TestProvider")
    expect(error.message).to eq("test error")
    expect(error.status_code).to eq(500)
    expect(error.provider).to eq("TestProvider")
  end

  it "defaults status_code and provider to nil" do
    error = described_class.new("simple error")
    expect(error.status_code).to be_nil
    expect(error.provider).to be_nil
  end

  it "inherits from StandardError" do
    expect(described_class.ancestors).to include(StandardError)
  end

  it "can be rescued as StandardError" do
    expect do
      raise described_class, "test"
    end.to raise_error(StandardError)
  end
end

RSpec.describe Dispatch::Adapter::AuthenticationError do
  it "inherits from Error" do
    expect(described_class.ancestors).to include(Dispatch::Adapter::Error)
  end
end

RSpec.describe Dispatch::Adapter::RateLimitError do
  it "carries retry_after" do
    error = described_class.new("rate limited", status_code: 429, provider: "Test", retry_after: 30)
    expect(error.retry_after).to eq(30)
    expect(error.status_code).to eq(429)
  end

  it "defaults retry_after to nil" do
    error = described_class.new("rate limited")
    expect(error.retry_after).to be_nil
  end

  it "is rescuable as Dispatch::Adapter::Error" do
    expect do
      raise described_class, "rate limited"
    end.to raise_error(Dispatch::Adapter::Error)
  end
end

RSpec.describe Dispatch::Adapter::ServerError do
  it "inherits from Error" do
    expect(described_class.ancestors).to include(Dispatch::Adapter::Error)
  end
end

RSpec.describe Dispatch::Adapter::RequestError do
  it "inherits from Error" do
    expect(described_class.ancestors).to include(Dispatch::Adapter::Error)
  end
end

RSpec.describe Dispatch::Adapter::ConnectionError do
  it "inherits from Error" do
    expect(described_class.ancestors).to include(Dispatch::Adapter::Error)
  end
end
