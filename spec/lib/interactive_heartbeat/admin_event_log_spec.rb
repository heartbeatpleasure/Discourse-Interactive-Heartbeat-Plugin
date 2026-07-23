# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::AdminEventLog do
  before { described_class.clear }
  after { described_class.clear }

  it "stores only bounded privacy-safe fields" do
    described_class.record(
      category: "session",
      event: "session_start",
      result: "started",
      severity: "info",
      client_context: "mobile_browser",
    )

    event = described_class.recent.first
    expect(event).to include(
      category: "session",
      event: "session_start",
      result: "started",
      severity: "info",
      client_context: "mobile_browser",
    )
    expect(event.keys).to contain_exactly(
      :id,
      :occurred_at,
      :occurred_at_ms,
      :severity,
      :category,
      :event,
      :result,
      :client_context,
    )
  end

  it "sanitizes unsupported free-form values" do
    described_class.record(
      category: "username: private-user",
      event: "session token abc",
      result: "provider response details",
      severity: "fatal",
      client_context: "full user agent",
    )

    expect(described_class.recent.first).to include(
      category: "system",
      event: "unknown",
      result: "unknown",
      severity: "info",
      client_context: "unknown",
    )
  end

  it "filters and counts bounded events" do
    described_class.record(
      category: "lovense",
      event: "lovense_callback",
      result: "success",
      occurred_at: 10.minutes.ago,
    )
    described_class.record(
      category: "security",
      event: "request_rate_limit",
      result: "limit_reached",
      severity: "warning",
      occurred_at: 5.minutes.ago,
    )

    expect(described_class.recent(category: "lovense").length).to eq(1)
    expect(
      described_class.count_since(
        since: 30.minutes.ago,
        category: "security",
        severity: "warning",
      ),
    ).to eq(1)
  end

  it "removes events outside the retention window" do
    described_class.record(
      category: "cleanup",
      event: "cleanup",
      result: "success",
      occurred_at: 8.days.ago,
    )

    expect(described_class.recent).to be_empty
  end
end
