# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::TestLabSignal do
  fab!(:admin) { Fabricate(:admin) }

  before do
    SiteSetting.interactive_heartbeat_signal_unstable_seconds = 5
    SiteSetting.interactive_heartbeat_signal_stale_seconds = 12
    SiteSetting.interactive_heartbeat_default_pulse_strength = 12
    SiteSetting.interactive_heartbeat_default_pulse_duration_ms = 180
  end

  def signal(**overrides)
    parameters = {
      "source_a_kind" => "simulated",
      "source_a_bpm" => 75,
      "source_b_kind" => "simulated",
      "source_b_bpm" => 95,
      "mode" => InteractiveHeartbeat::Session::MODE_CROSS_HEARTBEAT,
      "leader_source" => "A",
      "settings" => {
        "response_mode" => "fixed",
        "min_intensity" => 3,
        "max_intensity" => 12,
        "pulse_strength" => 8,
        "pulse_duration_ms" => 180,
      },
    }.merge(overrides.stringify_keys)

    described_class.for(user: admin, parameters: parameters)
  end

  it "uses source B as the Cross Heartbeat tempo" do
    payload = signal("source_b_bpm" => 100)

    expect(payload[:active]).to eq(true)
    expect(payload.dig(:control, :tempo_bpm)).to eq(100)
    expect(payload.dig(:pulse, :desired_strength)).to eq(8)
    expect(payload.dig(:pulse, :interval_ms)).to eq(600)
  end

  it "uses source B for tempo and source A for intensity in Shared Control" do
    payload = signal(
      "mode" => InteractiveHeartbeat::Session::MODE_SHARED_CONTROL,
      "source_a_bpm" => 120,
      "source_b_bpm" => 80,
      "settings" => {
        "response_mode" => "smooth",
        "min_intensity" => 2,
        "max_intensity" => 18,
        "smooth_min_bpm" => 60,
        "smooth_max_bpm" => 140,
      },
    )

    expect(payload.dig(:control, :tempo_bpm)).to eq(80)
    expect(payload.dig(:control, :intensity_bpm)).to eq(120)
    expect(payload.dig(:pulse, :desired_strength)).to eq(14)
  end

  it "calculates a Heart Sync score and keeps intensity within personal limits" do
    payload = signal(
      "mode" => InteractiveHeartbeat::Session::MODE_HEART_SYNC,
      "source_a_bpm" => 90,
      "source_b_bpm" => 95,
      "settings" => { "min_intensity" => 4, "max_intensity" => 10 },
    )

    expect(payload.dig(:control, :sync_score)).to eq(85)
    expect(payload.dig(:control, :heartbeat_difference)).to eq(5)
    expect(payload.dig(:pulse, :desired_strength)).to be_between(4, 10)
  end

  it "returns an inactive signal when a required simulated source is unavailable" do
    payload = signal(
      "mode" => InteractiveHeartbeat::Session::MODE_SHARED_AVERAGE,
      "source_b_kind" => "unavailable",
    )

    expect(payload[:active]).to eq(false)
    expect(payload[:reason]).to eq("source_missing")
  end
end
