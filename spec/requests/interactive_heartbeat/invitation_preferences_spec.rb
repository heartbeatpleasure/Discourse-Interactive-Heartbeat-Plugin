# frozen_string_literal: true

RSpec.describe "Interactive Heartbeat invitation preferences", type: :request do
  fab!(:sender) { Fabricate(:user) }
  fab!(:recipient) { Fabricate(:user) }
  fab!(:other_user) { Fabricate(:user) }

  before do
    SiteSetting.interactive_heartbeat_enabled = true
    SiteSetting.interactive_heartbeat_allowed_groups = "trust_level_0"
    SiteSetting.interactive_heartbeat_allow_nobody_invitation_preference = false
    SiteSetting.interactive_heartbeat_max_open_sessions_per_user = 5
    SiteSetting.interactive_heartbeat_declined_invite_cooldown_minutes = 60
    SiteSetting.interactive_heartbeat_invites_per_day = 20
    SiteSetting.interactive_heartbeat_max_invitation_list_members = 100
  end

  def create_invitation(from:, to:)
    sign_in(from)
    post "/interactive-heartbeat/api/sessions.json",
         params: {
           username: to.username,
           directions: [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
         },
         as: :json
    response
  end

  it "defaults to all members and returns avatar-ready approved and blocked lists" do
    InteractiveHeartbeat::InvitationMember.create!(
      owner_user: recipient,
      member_user: other_user,
      kind: InteractiveHeartbeat::InvitationMember::KIND_BLOCKED,
    )

    sign_in(recipient)
    get "/interactive-heartbeat/api/invitation-preferences.json"

    expect(response.status).to eq(200)
    expect(response.parsed_body["mode"]).to eq("all_members")
    expect(response.parsed_body["available_modes"]).to eq(%w[all_members approved_members])
    expect(response.parsed_body.dig("blocked_members", 0, "username")).to eq(other_user.username)
    expect(response.parsed_body.dig("blocked_members", 0, "avatar_template")).to be_present
  end

  it "allows only approved members when approved-only mode is selected" do
    sign_in(recipient)
    put "/interactive-heartbeat/api/invitation-preferences.json",
        params: { mode: "approved_members" },
        as: :json
    expect(response.status).to eq(200)

    create_invitation(from: sender, to: recipient)
    expect(response.status).to eq(422)
    expect(response.parsed_body["error"]).to eq("invitation_not_accepted")

    sign_in(recipient)
    post "/interactive-heartbeat/api/invitation-preferences/members.json",
         params: { username: sender.username, kind: "approved" },
         as: :json
    expect(response.status).to eq(200)

    create_invitation(from: sender, to: recipient)
    expect(response.status).to eq(201)
  end

  it "blocks new invitations and silently closes an unanswered invitation" do
    create_invitation(from: sender, to: recipient)
    expect(response.status).to eq(201)
    token = response.parsed_body["token"]

    sign_in(recipient)
    post "/interactive-heartbeat/api/invitation-preferences/members.json",
         params: { username: sender.username, kind: "blocked" },
         as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body["cancelled_invitations"]).to eq(1)
    expect(InteractiveHeartbeat::Session.find_by(token: token).status).to eq(
      InteractiveHeartbeat::Session::STATUS_DECLINED,
    )

    create_invitation(from: sender, to: recipient)
    expect(response.status).to eq(422)
    expect(response.parsed_body["message"]).to eq(
      "This member is not accepting Interactive Heartbeat invitations.",
    )
  end

  it "does not end an already accepted session when a member is added to the block list" do
    create_invitation(from: sender, to: recipient)
    token = response.parsed_body["token"]

    sign_in(recipient)
    put "/interactive-heartbeat/api/sessions/#{token}/join.json", params: {}, as: :json
    expect(response.status).to eq(200)

    post "/interactive-heartbeat/api/invitation-preferences/members.json",
         params: { username: sender.username, kind: "blocked" },
         as: :json
    expect(response.status).to eq(200)
    expect(InteractiveHeartbeat::Session.find_by(token: token).status).to eq(
      InteractiveHeartbeat::Session::STATUS_SETUP,
    )

    create_invitation(from: sender, to: recipient)
    expect(response.status).to eq(200)
    expect(response.parsed_body["token"]).to eq(token)
  end

  it "only exposes the nobody option when administrators enable it" do
    sign_in(recipient)
    put "/interactive-heartbeat/api/invitation-preferences.json",
        params: { mode: "nobody" },
        as: :json
    expect(response.status).to eq(422)

    SiteSetting.interactive_heartbeat_allow_nobody_invitation_preference = true
    put "/interactive-heartbeat/api/invitation-preferences.json",
        params: { mode: "nobody" },
        as: :json
    expect(response.status).to eq(200)
    expect(response.parsed_body["mode"]).to eq("nobody")
    expect(response.parsed_body["available_modes"]).to include("nobody")
  end

  it "enforces the declined invitation cooldown after a block is removed" do
    create_invitation(from: sender, to: recipient)
    token = response.parsed_body["token"]

    sign_in(recipient)
    put "/interactive-heartbeat/api/sessions/#{token}/decline.json", as: :json
    expect(response.status).to eq(200)

    create_invitation(from: sender, to: recipient)
    expect(response.status).to eq(422)
    expect(response.parsed_body["error"]).to eq("invitation_cooldown")
  end
end
