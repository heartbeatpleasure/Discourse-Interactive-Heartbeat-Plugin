# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::Participant do
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_presence_timeout_seconds = 20
    SiteSetting.interactive_heartbeat_default_pulse_strength = 12
    SiteSetting.interactive_heartbeat_default_pulse_duration_ms = 180
  end

  def active_session
    session = InteractiveHeartbeat::Session.create!(
      initiator: initiator,
      invitee: invitee,
      status: InteractiveHeartbeat::Session::STATUS_SETUP,
      mode: InteractiveHeartbeat::Session::MODE_HEARTBEAT_PULSE,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
        "show_exact_bpm" => false,
      },
      expires_at: 1.hour.from_now,
    )
    source = session.participants.create!(
      user: initiator,
      role: described_class::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      heartbeat_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
      presence_at: Time.zone.now,
    )
    target = session.participants.create!(
      user: invitee,
      role: described_class::ROLE_INVITEE,
      accepted_at: Time.zone.now,
      toy_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
      presence_at: Time.zone.now,
    )
    session.start!
    [session.reload, source.reload, target.reload]
  end

  it "never lets pulse strength exceed the participant maximum" do
    participant = described_class.new(
      settings: {
        "max_intensity" => 8,
        "pulse_strength" => 20,
        "pulse_duration_ms" => 180,
      },
    )

    participant.valid?

    expect(participant.max_intensity).to eq(8)
    expect(participant.pulse_strength).to eq(8)
  end

  it "pauses an active session when ready status is withdrawn" do
    session, _source, target = active_session

    target.update_preferences!(
      heartbeat_consent: false,
      toy_consent: true,
      ready: false,
      settings: target.settings_hash,
    )

    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_PAUSED)
    expect(session.participants.reload).to all(satisfy { |participant| participant.ready_at.nil? })
  end

  it "pauses an active session when toy consent is revoked" do
    session, _source, target = active_session

    target.update_preferences!(
      heartbeat_consent: false,
      toy_consent: false,
      ready: false,
      settings: target.settings_hash,
    )

    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_PAUSED)
    expect(target.reload.toy_consent?).to eq(false)
  end
end
