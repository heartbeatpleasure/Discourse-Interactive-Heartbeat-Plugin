# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::LovenseCallbackStore do
  fab!(:user)

  before { SiteSetting.interactive_heartbeat_lovense_callback_ttl_seconds = 60 }
  after { described_class.delete(user) }

  it "stores only temporary sanitized callback status" do
    state = described_class.write(
      user: user,
      payload: {
        appType: "remote",
        platform: "android",
        appVersion: "7.0.0",
        version: "101",
        domain: "192-168-1-10.lovense.club",
        httpsPort: "34568",
        toys: {
          "secret-toy-id" => {
            id: "secret-toy-id",
            name: "Lush",
            nickName: "Private toy name",
            status: 1,
          },
        },
      },
    )

    expect(state).to include(
      app_type: "remote",
      platform: "android",
      app_version: "7.0.0",
      protocol_version: "101",
      toy_count: 1,
      online_toy_count: 1,
    )

    raw = Discourse.redis.get(described_class.key(user))
    expect(raw).not_to include("secret-toy-id")
    expect(raw).not_to include("Private toy name")
    expect(raw).not_to include("lovense.club")
    expect(raw).not_to include("34568")
  end

  it "expires callback state using the configured bounded ttl" do
    SiteSetting.interactive_heartbeat_lovense_callback_ttl_seconds = 5
    described_class.write(user: user, payload: {})

    expect(Discourse.redis.ttl(described_class.key(user))).to be_between(1, 20)
  end
end
