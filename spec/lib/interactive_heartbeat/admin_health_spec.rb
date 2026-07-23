# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::AdminHealth do
  before do
    SiteSetting.interactive_heartbeat_enabled = true
    SiteSetting.interactive_heartbeat_lovense_developer_token = "test-token"
    SiteSetting.interactive_heartbeat_lovense_platform_name = "heartbeatpleasure"
    InteractiveHeartbeat::AdminEventLog.clear
  end

  after { InteractiveHeartbeat::AdminEventLog.clear }

  it "returns aggregate health without participant or heartbeat data" do
    summary = described_class.summary
    serialized = JSON.generate(summary)

    expect(summary.dig(:database, :ready)).to eq(true)
    expect(summary.dig(:configuration, :lovense_configured)).to eq(true)
    expect(serialized).not_to include(
      "username",
      "user_id",
      "session_token",
      "toy_id",
      "heart_rate",
      "auth_token",
      "developer_token",
      "access_token",
      "email",
    )
  end

  it "reports stale active sessions without exposing participants" do
    initiator = Fabricate(:user)
    invitee = Fabricate(:user)
    session = InteractiveHeartbeat::Session.create!(
      initiator_id: initiator.id,
      invitee_id: invitee.id,
      status: InteractiveHeartbeat::Session::STATUS_ACTIVE,
      mode: InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
      },
      expires_at: 1.hour.from_now,
    )
    session.participants.create!(
      user_id: initiator.id,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      presence_at: 1.hour.ago,
    )
    session.participants.create!(
      user_id: invitee.id,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      accepted_at: Time.zone.now,
      presence_at: Time.zone.now,
    )

    summary = described_class.summary

    expect(summary.dig(:sessions, :active)).to eq(1)
    expect(summary.dig(:sessions, :stale_active)).to eq(1)
    expect(summary[:warnings].map { |item| item[:code] }).to include("stale_active_sessions")
  end
end
