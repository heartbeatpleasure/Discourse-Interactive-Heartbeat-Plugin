# frozen_string_literal: true

class CreateInteractiveHeartbeatSessions < ActiveRecord::Migration[7.0]
  def change
    create_table :interactive_heartbeat_sessions do |t|
      t.string :token, null: false
      t.bigint :initiator_id, null: false
      t.bigint :invitee_id, null: false
      t.string :status, null: false, default: "invited"
      t.string :mode, null: false, default: "heartbeat_pulse"
      t.jsonb :settings, null: false, default: {}
      t.datetime :expires_at, null: false
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
    end

    add_index :interactive_heartbeat_sessions, :token, unique: true
    add_index :interactive_heartbeat_sessions, :initiator_id
    add_index :interactive_heartbeat_sessions, :invitee_id
    add_index :interactive_heartbeat_sessions, :status
    add_foreign_key :interactive_heartbeat_sessions, :users, column: :initiator_id, on_delete: :cascade
    add_foreign_key :interactive_heartbeat_sessions, :users, column: :invitee_id, on_delete: :cascade

    create_table :interactive_heartbeat_participants do |t|
      t.bigint :session_id, null: false
      t.bigint :user_id, null: false
      t.string :role, null: false
      t.datetime :accepted_at
      t.datetime :declined_at
      t.datetime :heartbeat_consent_at
      t.datetime :toy_consent_at
      t.datetime :ready_at
      t.datetime :presence_at
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end

    add_index :interactive_heartbeat_participants,
              %i[session_id user_id],
              unique: true,
              name: "idx_interactive_heartbeat_participants_unique"
    add_index :interactive_heartbeat_participants, :user_id
    add_foreign_key :interactive_heartbeat_participants,
                    :interactive_heartbeat_sessions,
                    column: :session_id,
                    on_delete: :cascade
    add_foreign_key :interactive_heartbeat_participants,
                    :users,
                    column: :user_id,
                    on_delete: :cascade
  end
end
