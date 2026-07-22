# frozen_string_literal: true

RSpec.describe "Interactive Heartbeat session lifecycle", type: :request do
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_enabled = true
    SiteSetting.interactive_heartbeat_allowed_groups = "trust_level_0"
    SiteSetting.interactive_heartbeat_invite_expiry_minutes = 60
  end

  def create_session(status:, ended_at: nil, updated_at: Time.zone.now, index: 0)
    session = InteractiveHeartbeat::Session.create!(
      initiator: initiator,
      invitee: invitee,
      status: status,
      mode: InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
        "configuration_revision" => 1,
      },
      expires_at: 1.hour.from_now,
      ended_at: ended_at,
      created_at: updated_at - 1.minute,
      updated_at: updated_at,
    )

    session.participants.create!(
      user: initiator,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      heartbeat_consent_at: Time.zone.now,
      settings: { "accepted_configuration_revision" => 1, "test_index" => index },
    )
    session.participants.create!(
      user: invitee,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      accepted_at: Time.zone.now,
      toy_consent_at: Time.zone.now,
      settings: { "accepted_configuration_revision" => 1, "test_index" => index },
    )
    session
  end

  it "shows every current session and only the five most recent completed sessions by default" do
    current = create_session(
      status: InteractiveHeartbeat::Session::STATUS_SETUP,
      updated_at: 2.minutes.ago,
    )
    completed = 7.times.map do |index|
      time = (index + 1).hours.ago
      create_session(
        status: InteractiveHeartbeat::Session::STATUS_ENDED,
        ended_at: time,
        updated_at: time,
        index: index,
      )
    end

    sign_in(initiator)
    get "/interactive-heartbeat/api/sessions.json"

    expect(response.status).to eq(200)
    body = response.parsed_body
    expect(body.dig("history", "total")).to eq(7)
    expect(body.dig("history", "shown")).to eq(5)
    expect(body.dig("history", "has_more")).to eq(true)

    sessions = body.fetch("sessions")
    expect(sessions.map { |row| row["token"] }).to include(current.token)
    terminal_rows = sessions.select { |row| row["terminal"] }
    expect(terminal_rows.length).to eq(5)
    expect(terminal_rows).to all(include("can_open" => false, "can_copy_invite" => false))
    expect(terminal_rows).to all(satisfy { |row| row["activity_at"].present? })
    expect(terminal_rows.first["token"]).to eq(completed.first.token)
  end

  it "can expand completed history and dismiss it only for the current participant" do
    completed = 7.times.map do |index|
      time = (index + 1).hours.ago
      create_session(
        status: InteractiveHeartbeat::Session::STATUS_ENDED,
        ended_at: time,
        updated_at: time,
        index: index,
      )
    end

    InteractiveHeartbeat::SessionNotifier.notify!(
      session: completed.first,
      recipient: initiator,
      actor: invitee,
      event: "session_ended",
    )

    sign_in(initiator)
    get "/interactive-heartbeat/api/sessions.json", params: { history_all: true }
    expect(response.status).to eq(200)
    expect(response.parsed_body.dig("history", "shown")).to eq(7)

    delete "/interactive-heartbeat/api/sessions/completed.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["cleared"]).to eq(7)
    expect(
      Notification.where(
        user_id: initiator.id,
        notification_type: Notification.types.fetch(:interactive_heartbeat),
      ).count,
    ).to eq(0)

    expect(
      InteractiveHeartbeat::Participant.where(
        user: initiator,
        session_id: completed.map(&:id),
      ).where.not(dismissed_at: nil).count,
    ).to eq(7)
    expect(
      InteractiveHeartbeat::Participant.where(
        user: invitee,
        session_id: completed.map(&:id),
        dismissed_at: nil,
      ).count,
    ).to eq(7)

    get "/interactive-heartbeat/api/sessions.json"
    expect(response.parsed_body.dig("history", "total")).to eq(0)

    sign_in(invitee)
    get "/interactive-heartbeat/api/sessions.json", params: { history_all: true }
    expect(response.parsed_body.dig("history", "total")).to eq(7)
  end

  it "creates in-app notifications for invitations and accepted invitations" do
    type = Notification.types.fetch(:interactive_heartbeat)

    sign_in(initiator)
    post "/interactive-heartbeat/api/sessions.json",
         params: {
           username: invitee.username,
           directions: [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
         },
         as: :json

    expect(response.status).to eq(201)
    token = response.parsed_body["token"]
    invitation = Notification.find_by(user_id: invitee.id, notification_type: type)
    expect(invitation).to be_present
    expect(JSON.parse(invitation.data)).to include(
      "event" => "invitation",
      "session_token" => token,
      "url" => "/interactive-heartbeat/sessions/#{token}",
    )

    sign_in(invitee)
    put "/interactive-heartbeat/api/sessions/#{token}/join.json", params: {}, as: :json
    expect(response.status).to eq(200)

    accepted = Notification
      .where(user_id: initiator.id, notification_type: type)
      .detect { |notification| JSON.parse(notification.data)["event"] == "invitation_accepted" }
    expect(accepted).to be_present
  end
end
RUB
