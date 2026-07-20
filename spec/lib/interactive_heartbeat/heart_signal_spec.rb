# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::HeartSignal do
  fab!(:source_user) { Fabricate(:user) }
  fab!(:target_user) { Fabricate(:user) }
  fab!(:source_account) do
    LiveMetrics::ProviderAccount.create!(
      user: source_user,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "interactive-heartbeat-source",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
  end

  before do
    SiteSetting.live_metrics_enabled = true
    SiteSetting.live_metrics_hyperate_enabled = true
    SiteSetting.live_metrics_async_current_readings_enabled = true
    SiteSetting.interactive_heartbeat_signal_stale_seconds = 8
    SiteSetting.interactive_heartbeat_signal_poll_ms = 1000
    SiteSetting.interactive_heartbeat_presence_timeout_seconds = 20
    LiveMetrics::RefreshCoordinator.stubs(:async_enabled?).returns(true)
  end

  after do
    LiveMetrics::CurrentStateStore.delete(source_account)
  end

  def active_session
    session = InteractiveHeartbeat::Session.create!(
      initiator: source_user,
      invitee: target_user,
      status: InteractiveHeartbeat::Session::STATUS_ACTIVE,
      mode: InteractiveHeartbeat::Session::MODE_HEARTBEAT_PULSE,
      settings: {
        "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
        "show_exact_bpm" => false,
      },
      expires_at: 1.hour.from_now,
      started_at: Time.zone.now,
    )
    session.participants.create!(
      user: source_user,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      heartbeat_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
      presence_at: Time.zone.now,
    )
    target = session.participants.create!(
      user: target_user,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      accepted_at: Time.zone.now,
      toy_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
      presence_at: Time.zone.now,
      settings: {
        "max_intensity" => 10,
        "pulse_strength" => 9,
        "pulse_duration_ms" => 180,
      },
    )
    [session.reload, target.reload]
  end

  it "converts a fresh BPM reading into a private heartbeat pulse signal" do
    session, target = active_session
    LiveMetrics::CurrentStateStore.write(
      source_account,
      status: "live",
      heart_rate: 80,
      measured_at_ms: (Time.zone.now.to_f * 1000).to_i,
    )

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(true)
    expect(signal.dig(:pulse, :interval_ms)).to be_within(2).of(750)
    expect(signal.dig(:pulse, :strength)).to eq(9)
    expect(signal.dig(:source, :heart_rate)).to be_nil
    expect(signal[:expires_at_ms] - signal[:server_time_ms]).to be <= 2500
  end

  it "pauses the session instead of reusing a stale reading" do
    session, target = active_session
    LiveMetrics::CurrentStateStore.write(
      source_account,
      status: "live",
      heart_rate: 80,
      measured_at_ms: (20.seconds.ago.to_f * 1000).to_i,
    )

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(false)
    expect(signal[:reason]).to eq("no_fresh_heartbeat")
    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_PAUSED)
  end
end
