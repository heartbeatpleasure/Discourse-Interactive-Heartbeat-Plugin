# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::HeartSignal do
  fab!(:initiator) { Fabricate(:user) }
  fab!(:invitee) { Fabricate(:user) }
  fab!(:initiator_account) do
    LiveMetrics::ProviderAccount.create!(
      user: initiator,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "interactive-heartbeat-initiator",
      visibility: "private",
      active: true,
      show_on_profile: false,
      show_on_user_card: false,
      show_in_directory: false,
    )
  end
  fab!(:invitee_account) do
    LiveMetrics::ProviderAccount.create!(
      user: invitee,
      provider: LiveMetrics::ProviderAccount::PROVIDER_HYPERATE,
      provider_uid: "interactive-heartbeat-invitee",
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
    SiteSetting.interactive_heartbeat_signal_unstable_seconds = 5
    SiteSetting.interactive_heartbeat_signal_stale_seconds = 12
    SiteSetting.interactive_heartbeat_signal_poll_ms = 1000
    SiteSetting.interactive_heartbeat_presence_timeout_seconds = 20
    LiveMetrics::RefreshCoordinator.stubs(:async_enabled?).returns(true)
  end

  after do
    LiveMetrics::CurrentStateStore.delete(initiator_account)
    LiveMetrics::CurrentStateStore.delete(invitee_account)
  end

  def write_reading(account, bpm, measured_at: Time.zone.now)
    LiveMetrics::CurrentStateStore.write(
      account,
      status: "live",
      heart_rate: bpm,
      measured_at_ms: (measured_at.to_f * 1000).to_i,
    )
  end

  def active_session(mode: InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT, target_settings: {}, leader_user_id: nil)
    settings = {
      "directions" => [InteractiveHeartbeat::Session::DIRECTION_INITIATOR_TO_INVITEE],
      "show_exact_bpm" => false,
      "configuration_revision" => 1,
    }
    settings["leader_user_id"] = leader_user_id if leader_user_id

    session = InteractiveHeartbeat::Session.create!(
      initiator: initiator,
      invitee: invitee,
      status: InteractiveHeartbeat::Session::STATUS_ACTIVE,
      mode: mode,
      settings: settings,
      expires_at: 1.hour.from_now,
      started_at: Time.zone.now,
    )
    session.participants.create!(
      user: initiator,
      role: InteractiveHeartbeat::Participant::ROLE_INITIATOR,
      accepted_at: Time.zone.now,
      heartbeat_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
      presence_at: Time.zone.now,
    )
    target = session.participants.create!(
      user: invitee,
      role: InteractiveHeartbeat::Participant::ROLE_INVITEE,
      accepted_at: Time.zone.now,
      heartbeat_consent_at: Time.zone.now,
      toy_consent_at: Time.zone.now,
      ready_at: Time.zone.now,
      presence_at: Time.zone.now,
      settings: {
        "max_intensity" => 10,
        "pulse_strength" => 9,
        "pulse_duration_ms" => 180,
      }.merge(target_settings),
    )
    [session.reload, target.reload]
  end

  it "keeps the existing cross-heartbeat behavior as the compatible default" do
    session, target = active_session
    write_reading(initiator_account, 80)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(true)
    expect(signal[:mode]).to eq(InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT)
    expect(signal[:signal_state]).to eq("live")
    expect(signal.dig(:pulse, :interval_ms)).to be_within(2).of(750)
    expect(signal.dig(:pulse, :strength)).to eq(9)
    expect(signal.dig(:response, :mode)).to eq("fixed")
    expect(signal.dig(:source, :heart_rate)).to be_nil
    expect(signal[:source_age_ms]).to be < 1000
  end

  it "maps heartbeat input smoothly inside the toy owner's personal range" do
    session, target = active_session(
      target_settings: {
        "response_mode" => "smooth",
        "min_intensity" => 2,
        "max_intensity" => 12,
        "smooth_min_bpm" => 60,
        "smooth_max_bpm" => 160,
      },
    )
    write_reading(initiator_account, 100)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal.dig(:response, :mode)).to eq("smooth")
    expect(signal.dig(:response, :desired_strength)).to eq(6)
    expect(signal.dig(:pulse, :strength)).to eq(6)
  end

  it "uses the partner for tempo and the toy owner for intensity in shared control" do
    session, target = active_session(
      mode: InteractiveHeartbeat::Session::MODE_SHARED_CONTROL,
      target_settings: {
        "response_mode" => "smooth",
        "min_intensity" => 2,
        "max_intensity" => 18,
        "smooth_min_bpm" => 60,
        "smooth_max_bpm" => 140,
      },
    )
    write_reading(initiator_account, 80)
    write_reading(invitee_account, 120)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal.dig(:control, :tempo_bpm)).to eq(80)
    expect(signal.dig(:control, :intensity_bpm)).to eq(120)
    expect(signal.dig(:pulse, :interval_ms)).to be_within(2).of(750)
    expect(signal.dig(:pulse, :strength)).to eq(14)
  end

  it "calculates a shared rhythm and bounded sync intensity in heart-sync mode" do
    session, target = active_session(
      mode: InteractiveHeartbeat::Session::MODE_HEART_SYNC,
      target_settings: { "min_intensity" => 2, "max_intensity" => 12 },
    )
    write_reading(initiator_account, 90)
    write_reading(invitee_account, 92)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal.dig(:control, :tempo_bpm)).to eq(91)
    expect(signal.dig(:control, :heartbeat_difference)).to eq(2)
    expect(signal.dig(:control, :sync_score)).to eq(94)
    expect(signal.dig(:response, :mode)).to eq("sync")
    expect(signal.dig(:pulse, :strength)).to be_between(2, 12)
  end

  it "supports average, highest and lowest joint heartbeat selection" do
    cases = {
      InteractiveHeartbeat::Session::MODE_SHARED_AVERAGE => 100,
      InteractiveHeartbeat::Session::MODE_HIGHEST_HEARTBEAT => 120,
      InteractiveHeartbeat::Session::MODE_LOWEST_HEARTBEAT => 80,
    }

    cases.each do |mode, expected_bpm|
      session, target = active_session(mode: mode)
      write_reading(initiator_account, 80)
      write_reading(invitee_account, 120)

      signal = described_class.for(session: session, target_participant: target)

      expect(signal.dig(:control, :tempo_bpm)).to eq(expected_bpm)
      expect(signal.dig(:control, :intensity_bpm)).to eq(expected_bpm)
      session.destroy!
    end
  end

  it "uses the selected leader for every enabled toy" do
    session, target = active_session(
      mode: InteractiveHeartbeat::Session::MODE_LEADER_FOLLOWER,
      leader_user_id: initiator.id,
    )
    write_reading(initiator_account, 100)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal.dig(:control, :leader_user_id)).to eq(initiator.id)
    expect(signal.dig(:control, :tempo_bpm)).to eq(100)
    expect(signal.dig(:pulse, :interval_ms)).to be_within(2).of(600)
  end

  it "keeps a command gap at high heart rates" do
    session, target = active_session
    write_reading(initiator_account, 220)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(true)
    expect(signal.dig(:pulse, :interval_ms)).to eq(273)
    expect(signal.dig(:pulse, :duration_ms)).to eq(133)
  end

  it "keeps using the required readings during the unstable grace window" do
    session, target = active_session(mode: InteractiveHeartbeat::Session::MODE_SHARED_AVERAGE)
    write_reading(initiator_account, 90, measured_at: 7.seconds.ago)
    write_reading(invitee_account, 100, measured_at: 6.seconds.ago)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(true)
    expect(signal[:signal_state]).to eq("unstable")
    expect(signal[:source_age_ms]).to be_between(6000, 8000)
    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_ACTIVE)
  end

  it "pauses the session after any required source crosses the hard loss threshold" do
    session, target = active_session(mode: InteractiveHeartbeat::Session::MODE_SHARED_AVERAGE)
    write_reading(initiator_account, 80, measured_at: 20.seconds.ago)
    write_reading(invitee_account, 90)

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(false)
    expect(signal[:reason]).to eq("no_fresh_heartbeat")
    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_PAUSED)
  end

  it "does not pause an active session for a transient state-store read error" do
    session, target = active_session
    LiveMetrics::CurrentStateStore.stubs(:read).raises(Redis::BaseError.new("temporary"))

    signal = described_class.for(session: session, target_participant: target)

    expect(signal[:active]).to eq(false)
    expect(signal[:reason]).to eq("signal_temporarily_unavailable")
    expect(session.reload.status).to eq(InteractiveHeartbeat::Session::STATUS_ACTIVE)
  end
end
