# frozen_string_literal: true

RSpec.describe "Interactive Heartbeat permissions and Test Lab", type: :request do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_enabled = true
    SiteSetting.interactive_heartbeat_allowed_groups = "trust_level_0"
    SiteSetting.interactive_heartbeat_test_lab_enabled = true
    SiteSetting.interactive_heartbeat_presence_timeout_seconds = 20
    SiteSetting.interactive_heartbeat_default_pulse_strength = 12
    SiteSetting.interactive_heartbeat_default_pulse_duration_ms = 180
  end

  def invited_session
    session = InteractiveHeartbeat::Session.create!(
      initiator: initiator,
      invitee: invitee,
      status: InteractiveHeartbeat::Session::STATUS_INVITED,
      mode: InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
        "configuration_revision" => 1,
      },
      expires_at: 1.hour.from_now,
    )
    session.participants.create!(
      user: initiator,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      heartbeat_consent_at: Time.zone.now,
      settings: {
        "permission_scope" => "session",
        "accepted_configuration_revision" => 1,
      },
    )
    session.participants.create!(
      user: invitee,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      settings: { "configuration_consent_revoked" => true },
    )
    session.reload
  end

  it "allows an invitee to join and grant all session-scoped permissions in one request" do
    session = invited_session
    sign_in(invitee)

    put "/interactive-heartbeat/api/sessions/#{session.token}/join",
        params: { settings: { max_intensity: 9, pulse_strength: 7 } },
        as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("current_user", "permissions_granted")).to eq(true)
    expect(response.parsed_body.dig("current_user", "settings", "max_intensity")).to eq(9)

    participant = session.participant_for(invitee).reload
    expect(participant.accepted?).to eq(true)
    expect(participant.session_permissions_granted?).to eq(true)
    expect(participant.heartbeat_consent?).to eq(true)
    expect(participant.toy_consent?).to eq(true)
  end

  it "keeps the Test Lab hidden from non-admin users" do
    sign_in(initiator)

    get "/interactive-heartbeat/test-lab"
    expect(response.status).to eq(404)

    post "/interactive-heartbeat/api/test-lab/signal",
         params: {
           test_lab: {
             source_a_kind: "simulated",
             source_a_bpm: 75,
             source_b_kind: "simulated",
             source_b_bpm: 95,
             mode: "cross_heartbeat",
           },
         },
         as: :json
    expect(response.status).to eq(404)
  end

  it "allows an administrator to use a simulated Test Lab signal" do
    sign_in(admin)

    post "/interactive-heartbeat/api/test-lab/signal",
         params: {
           test_lab: {
             source_a_kind: "simulated",
             source_a_bpm: 75,
             source_b_kind: "simulated",
             source_b_bpm: 100,
             mode: "cross_heartbeat",
             settings: {
               response_mode: "fixed",
               pulse_strength: 8,
               max_intensity: 12,
             },
           },
         },
         as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body["active"]).to eq(true)
    expect(response.parsed_body.dig("control", "tempo_bpm")).to eq(100)
    expect(response.parsed_body.dig("pulse", "desired_strength")).to eq(8)
  end
  it "drops unexpected participant and Test Lab parameters" do
    session = invited_session
    sign_in(invitee)

    put "/interactive-heartbeat/api/sessions/#{session.token}/join",
        params: {
          settings: {
            max_intensity: 9,
            injected_admin: true,
            permission_scope: "forged",
          },
        },
        as: :json

    expect(response.status).to eq(200)
    stored = session.participant_for(invitee).reload.settings
    expect(stored["max_intensity"]).to eq(9)
    expect(stored).not_to have_key("injected_admin")
    expect(stored["permission_scope"]).to eq("session")

    sign_in(admin)
    post "/interactive-heartbeat/api/test-lab/signal",
         params: {
           test_lab: {
             source_a_kind: "simulated",
             source_a_bpm: 75,
             source_b_kind: "simulated",
             source_b_bpm: 95,
             mode: "cross_heartbeat",
             unexpected_source: "ignored",
             settings: {
               response_mode: "fixed",
               pulse_strength: 8,
               max_intensity: 12,
               injected_admin: true,
             },
           },
         },
         as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body["active"]).to eq(true)
  end

end
