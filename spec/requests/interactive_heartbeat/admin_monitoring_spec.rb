# frozen_string_literal: true

RSpec.describe "Interactive Heartbeat admin monitoring", type: :request do
  fab!(:admin)
  fab!(:user)

  before do
    SiteSetting.interactive_heartbeat_enabled = true
    InteractiveHeartbeat::AdminEventLog.clear
  end

  after { InteractiveHeartbeat::AdminEventLog.clear }

  it "restricts health and events to administrators" do
    sign_in(user)

    get "/admin/plugins/interactive-heartbeat/health.json"
    expect(response.status).not_to eq(200)

    get "/admin/plugins/interactive-heartbeat/events.json"
    expect(response.status).not_to eq(200)
  end

  it "returns privacy-safe aggregate health" do
    sign_in(admin)

    get "/admin/plugins/interactive-heartbeat/health.json"

    expect(response.status).to eq(200)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body).to have_key("overall")
    expect(response.body).not_to include(
      "username",
      "session_token",
      "toy_id",
      "heart_rate",
      "developer_token",
      "access_token",
    )
  end

  it "returns filtered privacy-safe events" do
    InteractiveHeartbeat::AdminEventLog.record(
      category: "lovense",
      event: "lovense_callback",
      result: "rejected",
      severity: "warning",
      client_context: "server",
    )
    InteractiveHeartbeat::AdminEventLog.record(
      category: "session",
      event: "session_start",
      result: "started",
      severity: "info",
      client_context: "desktop_browser",
    )
    sign_in(admin)

    get "/admin/plugins/interactive-heartbeat/events.json",
        params: { category: "lovense", severity: "warning" }

    expect(response.status).to eq(200)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body["events"].length).to eq(1)
    expect(response.parsed_body.dig("events", 0, "event")).to eq("lovense_callback")
    expect(response.body).not_to include(
      "username",
      "user_id",
      "session_token",
      "toy_id",
      "heart_rate",
    )
  end
  it "serves all admin monitoring frontend routes to administrators" do
    sign_in(admin)

    get "/admin/plugins/interactive-heartbeat"
    expect(response.status).to eq(200)

    get "/admin/plugins/interactive-heartbeat-health"
    expect(response.status).to eq(200)

    get "/admin/plugins/interactive-heartbeat-events"
    expect(response.status).to eq(200)
  end

  it "does not expose admin monitoring frontend routes to regular users" do
    sign_in(user)

    get "/admin/plugins/interactive-heartbeat-health"
    expect(response.status).not_to eq(200)

    get "/admin/plugins/interactive-heartbeat-events"
    expect(response.status).not_to eq(200)
  end

end
