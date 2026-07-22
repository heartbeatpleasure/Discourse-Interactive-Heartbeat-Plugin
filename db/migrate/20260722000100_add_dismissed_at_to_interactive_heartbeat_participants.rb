# frozen_string_literal: true

class AddDismissedAtToInteractiveHeartbeatParticipants < ActiveRecord::Migration[7.0]
  def change
    add_column :interactive_heartbeat_participants, :dismissed_at, :datetime
    add_index :interactive_heartbeat_participants,
              %i[user_id dismissed_at],
              name: "idx_interactive_heartbeat_participants_dismissed"
  end
end
