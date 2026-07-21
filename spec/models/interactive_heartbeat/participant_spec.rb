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
      mode: InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
        "show_exact_bpm" => false,
        "configuration_revision" => 1,
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

  it "never lets fixed or zone intensity exceed the participant maximum" do
    participant = described_class.new(
      settings: {
        "max_intensity" => 8,
        "pulse_strength" => 20,
        "zone_peak_intensity" => 20,
        "pulse_duration_ms" => 180,
      },
    )

    participant.valid?

    expect(participant.max_intensity).to eq(8)
    expect(participant.pulse_strength).to eq(8)
    expect(participant.zone_peak_intensity).to eq(8)
  end

  it "normalizes zone thresholds into a strictly increasing order" do
    participant = described_class.new(
      settings: {
        "zone_low_max_bpm" => 100,
        "zone_medium_max_bpm" => 90,
        "zone_high_max_bpm" => 95,
      },
    )

    participant.valid?

    expect(participant.zone_medium_max_bpm).to be >= participant.zone_low_max_bpm + 5
    expect(participant.zone_high_max_bpm).to be >= participant.zone_medium_max_bpm + 5
  end

  it "pauses an active session when ready status is withdrawn" do
    session, _source, target = active_session

    target.update_preferences!(
      heartbeat_consent: false,
      toy_consent: true,
      configuration_consent: true,
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
      configuration_consent: true,
      ready: false,
      settings: target.settings_hash,
    )

    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_PAUSED)
    expect(target.reload.toy_consent?).to eq(false)
  end

  it "cannot become ready without accepting the current mode revision" do
    session, _source, target = active_session
    session.update!(
      status: InteractiveHeartbeat::Session::STATUS_PAUSED,
      settings: session.settings_hash.to_h.merge("configuration_revision" => 2),
    )

    target.update_preferences!(
      heartbeat_consent: false,
      toy_consent: true,
      configuration_consent: false,
      ready: true,
      settings: target.settings_hash,
    )

    expect(target.reload.ready?).to eq(false)
    expect(target.configuration_accepted?).to eq(false)
  end
  it "preserves configuration consent when an older client omits the new field" do
    session, _source, target = active_session
    expect(target.configuration_accepted?).to eq(true)

    target.update_preferences!(
      heartbeat_consent: false,
      toy_consent: true,
      configuration_consent: nil,
      ready: false,
      settings: target.settings_hash,
    )

    expect(target.reload.configuration_accepted?).to eq(true)
  end

  it "preserves fixed intensity values below the dynamic minimum" do
    participant = described_class.new(
      settings: {
        "response_mode" => "fixed",
        "min_intensity" => 3,
        "max_intensity" => 8,
        "pulse_strength" => 1,
      },
    )

    participant.valid?

    expect(participant.pulse_strength).to eq(1)
  end

end
