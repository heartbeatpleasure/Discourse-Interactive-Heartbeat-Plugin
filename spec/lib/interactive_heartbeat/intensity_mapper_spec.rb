# frozen_string_literal: true

RSpec.describe InteractiveHeartbeat::IntensityMapper do
  def participant(settings)
    row = InteractiveHeartbeat::Participant.new(settings: settings)
    row.valid?
    row
  end

  it "keeps fixed intensity within the toy owner's maximum without changing legacy low values" do
    row = participant(
      "response_mode" => "fixed",
      "min_intensity" => 3,
      "max_intensity" => 8,
      "pulse_strength" => 1,
    )

    payload = described_class.for(participant: row, input_bpm: 150)

    expect(payload[:desired_strength]).to eq(1)
    expect(payload[:mode]).to eq("fixed")
  end

  it "returns zone metadata needed for client-side hysteresis" do
    row = participant(
      "response_mode" => "zones",
      "min_intensity" => 2,
      "max_intensity" => 14,
      "zone_low_max_bpm" => 79,
      "zone_medium_max_bpm" => 99,
      "zone_high_max_bpm" => 119,
      "zone_low_intensity" => 3,
      "zone_medium_intensity" => 7,
      "zone_high_intensity" => 11,
      "zone_peak_intensity" => 14,
      "hysteresis_bpm" => 4,
    )

    payload = described_class.for(participant: row, input_bpm: 105)

    expect(payload[:zone_key]).to eq("high")
    expect(payload[:desired_strength]).to eq(11)
    expect(payload[:zone_thresholds]).to eq([79, 99, 119])
    expect(payload[:zone_intensities]).to eq(low: 3, medium: 7, high: 11, peak: 14)
    expect(payload[:hysteresis_bpm]).to eq(4)
  end

  it "interpolates smooth intensity between personal minimum and maximum" do
    row = participant(
      "response_mode" => "smooth",
      "min_intensity" => 2,
      "max_intensity" => 18,
      "smooth_min_bpm" => 60,
      "smooth_max_bpm" => 140,
    )

    expect(described_class.for(participant: row, input_bpm: 60)[:desired_strength]).to eq(2)
    expect(described_class.for(participant: row, input_bpm: 100)[:desired_strength]).to eq(10)
    expect(described_class.for(participant: row, input_bpm: 140)[:desired_strength]).to eq(18)
  end

  it "maps relative intensity from baseline to baseline plus range" do
    row = participant(
      "response_mode" => "relative",
      "min_intensity" => 3,
      "max_intensity" => 13,
      "baseline_bpm" => 70,
      "relative_range_bpm" => 50,
    )

    expect(described_class.for(participant: row, input_bpm: 70)[:desired_strength]).to eq(3)
    expect(described_class.for(participant: row, input_bpm: 95)[:desired_strength]).to eq(8)
    expect(described_class.for(participant: row, input_bpm: 120)[:desired_strength]).to eq(13)
  end

  it "maps sync scores without exceeding personal limits" do
    row = participant("min_intensity" => 4, "max_intensity" => 10)

    expect(described_class.for(participant: row, sync_score: 0)[:desired_strength]).to eq(4)
    expect(described_class.for(participant: row, sync_score: 50)[:desired_strength]).to eq(7)
    expect(described_class.for(participant: row, sync_score: 100)[:desired_strength]).to eq(10)
  end
end
