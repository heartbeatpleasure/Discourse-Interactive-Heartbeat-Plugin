# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::Session do
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_presence_timeout_seconds = 20
  end

  def build_session(directions: [described_class::DIRECTION_INITIATOR_TO_INVITEE])
    session = described_class.create!(
      initiator: initiator,
      invitee: invitee,
      status: described_class::STATUS_SETUP,
      mode: described_class::MODE_HEARTBEAT_PULSE,
      settings: { "directions" => directions, "show_exact_bpm" => false },
      expires_at: 1.hour.from_now,
    )
    session.participants.create!(
      user: initiator,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      presence_at: Time.zone.now,
    )
    session.participants.create!(
      user: invitee,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      accepted_at: Time.zone.now,
      presence_at: Time.zone.now,
    )
    session.reload
  end

  it "requires consent from the heartbeat owner and the toy owner per direction" do
    session = build_session
    source = session.participant_for(initiator)
    target = session.participant_for(invitee)

    source.update!(heartbeat_consent_at: Time.zone.now)
    expect(session.reload.required_consents_satisfied?).to eq(false)

    target.update!(toy_consent_at: Time.zone.now)
    expect(session.reload.required_consents_satisfied?).to eq(true)
  end

  it "supports two independent heartbeat directions" do
    session = build_session(directions: described_class::DIRECTIONS)
    initiator_participant = session.participant_for(initiator)
    invitee_participant = session.participant_for(invitee)

    initiator_participant.update!(heartbeat_consent_at: Time.zone.now, toy_consent_at: Time.zone.now)
    invitee_participant.update!(heartbeat_consent_at: Time.zone.now, toy_consent_at: Time.zone.now)

    expect(session.reload.required_consents_satisfied?).to eq(true)
    expect(session.direction_enabled?(initiator.id, invitee.id)).to eq(true)
    expect(session.direction_enabled?(invitee.id, initiator.id)).to eq(true)
  end

  it "pauses an active session when a participant is no longer present" do
    session = build_session
    source = session.participant_for(initiator)
    target = session.participant_for(invitee)
    source.update!(heartbeat_consent_at: Time.zone.now, ready_at: Time.zone.now)
    target.update!(toy_consent_at: Time.zone.now, ready_at: Time.zone.now)
    session.start!

    target.update_column(:presence_at, 1.minute.ago)

    expect(session.reload.refresh_presence_state!).to eq(true)
    expect(session.reload.status).to eq(described_class::STATUS_PAUSED)
    expect(session.participants.reload).to all(satisfy { |participant| participant.ready_at.nil? })
  end
end
