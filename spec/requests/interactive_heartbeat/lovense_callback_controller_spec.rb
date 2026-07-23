# frozen_string_literal: true

RSpec.describe "Interactive Heartbeat Lovense callback", type: :request do
  fab!(:user)

  before do
    SiteSetting.interactive_heartbeat_enabled = true
    SiteSetting.interactive_heartbeat_allowed_groups = "trust_level_0"
    SiteSetting.login_required = true
  end

  after { InteractiveHeartbeat::LovenseCallbackStore.delete(user) }

  def verification_token
    InteractiveHeartbeat::LovenseClient.send(:user_verification_token, user)
  end

  def callback_payload(overrides = {})
    {
      uid: user.id.to_s,
      utoken: verification_token,
      appVersion: "7.0.0",
      appType: "remote",
      platform: "android",
      version: "101",
      toys: {
        "toy-id" => {
          id: "toy-id",
          name: "Lush",
          status: 1,
        },
      },
    }.merge(overrides)
  end

  it "accepts a verified callback without a Discourse login or CSRF token" do
    post "/interactive-heartbeat/lovense/callback",
         params: callback_payload,
         as: :json

    expect(response.status).to eq(200)
    expect(response.parsed_body).to eq("result" => true)
    expect(InteractiveHeartbeat::LovenseCallbackStore.read(user)).to include(
      app_type: "remote",
      platform: "android",
      toy_count: 1,
      online_toy_count: 1,
    )
  end

  it "rejects a callback with an invalid verification token" do
    post "/interactive-heartbeat/lovense/callback",
         params: callback_payload(utoken: "0" * 64),
         as: :json

    expect(response.status).to eq(403)
    expect(response.parsed_body).to eq(
      "result" => false,
      "code" => "invalid_callback",
    )
    expect(InteractiveHeartbeat::LovenseCallbackStore.read(user)).to be_nil
  end

  it "rejects callbacks without uid or utoken" do
    post "/interactive-heartbeat/lovense/callback",
         params: { appType: "remote" },
         as: :json

    expect(response.status).to eq(422)
    expect(response.parsed_body).to eq(
      "result" => false,
      "code" => "invalid_callback",
    )
  end
  it "rejects oversized callback payloads before processing toy data" do
    post "/interactive-heartbeat/lovense/callback",
         params: callback_payload(toys: { "toy-id" => { status: 1, padding: "x" * 70_000 } }),
         as: :json

    expect(response.status).to eq(413)
    expect(response.parsed_body).to eq(
      "result" => false,
      "code" => "payload_too_large",
    )
    expect(InteractiveHeartbeat::LovenseCallbackStore.read(user)).to be_nil
  end

  it "rejects malformed callback identifiers without querying a user" do
    post "/interactive-heartbeat/lovense/callback",
         params: callback_payload(uid: "1 OR 1=1"),
         as: :json

    expect(response.status).to eq(422)
    expect(response.parsed_body["code"]).to eq("invalid_callback")
  end

end
