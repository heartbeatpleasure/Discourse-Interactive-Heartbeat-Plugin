# frozen_string_literal: true

RSpec.describe Jobs::InteractiveHeartbeat::Cleanup do
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_completed_session_retention_days = 30
  end

  def completed_session(ended_at:)
    session = InteractiveHeartbeat::Session.create!(
      initiator: initiator,
      invitee: invitee,
      status: InteractiveHeartbeat::Session::STATUS_ENDED,
      mode: InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
        "configuration_revision" => 1,
      },
      expires_at: 1.hour.from_now,
      ended_at: ended_at,
      updated_at: ended_at,
    )
    session.participants.create!(
      user: initiator,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: ended_at,
    )
    session.participants.create!(
      user: invitee,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      accepted_at: ended_at,
    )
    session
  end

  it "deletes only terminal sessions older than the configured retention period" do
    old_session = completed_session(ended_at: 31.days.ago)
    recent_session = completed_session(ended_at: 10.days.ago)

    described_class.new.execute({})

    expect(InteractiveHeartbeat::Session.exists?(old_session.id)).to eq(false)
    expect(InteractiveHeartbeat::Session.exists?(recent_session.id)).to eq(true)
  end
end
