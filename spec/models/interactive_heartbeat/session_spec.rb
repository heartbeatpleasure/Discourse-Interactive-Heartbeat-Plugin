# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::Session do
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_presence_timeout_seconds = 20
  end

  def build_session(
    directions: [described_class::DIRECTION_INITIATOR_TO_INVITEE],
    mode: described_class::MODE_CROSS_HEARTBEAT
  )
    session = described_class.create!(
      initiator: initiator,
      invitee: invitee,
      status: described_class::STATUS_SETUP,
      mode: mode,
      settings: {
        "directions" => directions,
        "show_exact_bpm" => false,
        "configuration_revision" => 1,
        "leader_user_id" => (mode == described_class::MODE_LEADER_FOLLOWER ? initiator.id : nil),
      }.compact,
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

  it "keeps legacy heartbeat pulse sessions compatible with Cross Heartbeat" do
    session = build_session(mode: described_class::MODE_HEARTBEAT_PULSE)

    expect(session.mode_key).to eq(described_class::MODE_CROSS_HEARTBEAT)
    expect(session.configuration_revision).to eq(1)
    expect(session.participants).to all(be_configuration_accepted)
  end

  it "requires consent from the heartbeat owner and toy owner in Cross Heartbeat" do
    session = build_session
    source = session.participant_for(initiator)
    target = session.participant_for(invitee)

    source.update!(heartbeat_consent_at: Time.zone.now)
    expect(session.reload.required_consents_satisfied?).to eq(false)

    target.update!(toy_consent_at: Time.zone.now)
    expect(session.reload.required_consents_satisfied?).to eq(true)
  end

  it "requires both heartbeats for shared modes" do
    session = build_session(mode: described_class::MODE_SHARED_AVERAGE)
    initiator_participant = session.participant_for(initiator)
    invitee_participant = session.participant_for(invitee)

    initiator_participant.update!(heartbeat_consent_at: Time.zone.now)
    invitee_participant.update!(toy_consent_at: Time.zone.now)
    expect(session.reload.required_consents_satisfied?).to eq(false)

    invitee_participant.update!(heartbeat_consent_at: Time.zone.now)
    expect(session.reload.required_consents_satisfied?).to eq(true)
  end

  it "supports two independent toy directions" do
    session = build_session(directions: described_class::DIRECTIONS)

    expect(session.direction_enabled?(initiator.id, invitee.id)).to eq(true)
    expect(session.direction_enabled?(invitee.id, initiator.id)).to eq(true)
    expect(session.target_user_ids).to contain_exactly(initiator.id, invitee.id)
  end

  it "pauses and resets readiness when a participant proposes a new shared mode" do
    session = build_session
    initiator_participant = session.participant_for(initiator)
    invitee_participant = session.participant_for(invitee)
    initiator_participant.update!(
      heartbeat_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
    )
    invitee_participant.update!(
      heartbeat_consent_at: Time.zone.now,
      toy_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
    )
    session.start!

    session.propose_configuration!(
      participant: initiator_participant,
      requested_mode: described_class::MODE_HEART_SYNC,
    )

    expect(session.reload.mode_key).to eq(described_class::MODE_HEART_SYNC)
    expect(session.status).to eq(described_class::STATUS_PAUSED)
    expect(session.configuration_revision).to eq(2)
    expect(initiator_participant.reload.configuration_accepted?).to eq(true)
    expect(invitee_participant.reload.configuration_accepted?).to eq(false)
    expect(session.participants).to all(satisfy { |participant| participant.ready_at.nil? })
  end

  it "requires a valid participant as leader" do
    session = build_session
    participant = session.participant_for(initiator)

    expect do
      session.propose_configuration!(
        participant: participant,
        requested_mode: described_class::MODE_LEADER_FOLLOWER,
        requested_leader_user_id: -1,
      )
    end.to raise_error(ActiveRecord::RecordInvalid)
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
