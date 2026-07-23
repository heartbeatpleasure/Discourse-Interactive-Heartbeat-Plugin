# frozen_string_literal: true

class AddInteractiveHeartbeatInvitationPreferences < ActiveRecord::Migration[7.0]
  def change
    create_table :interactive_heartbeat_invitation_preferences do |t|
      t.bigint :user_id, null: false
      t.string :mode, null: false, default: "all_members"
      t.timestamps
    end

    add_index :interactive_heartbeat_invitation_preferences, :user_id, unique: true,
              name: "idx_iheartbeat_invitation_preferences_user"
    add_foreign_key :interactive_heartbeat_invitation_preferences,
                    :users,
                    column: :user_id,
                    on_delete: :cascade

    create_table :interactive_heartbeat_invitation_members do |t|
      t.bigint :owner_user_id, null: false
      t.bigint :member_user_id, null: false
      t.string :kind, null: false
      t.timestamps
    end

    add_index :interactive_heartbeat_invitation_members,
              %i[owner_user_id member_user_id],
              unique: true,
              name: "idx_iheartbeat_invitation_members_unique"
    add_index :interactive_heartbeat_invitation_members,
              %i[owner_user_id kind],
              name: "idx_iheartbeat_invitation_members_kind"
    add_foreign_key :interactive_heartbeat_invitation_members,
                    :users,
                    column: :owner_user_id,
                    on_delete: :cascade
    add_foreign_key :interactive_heartbeat_invitation_members,
                    :users,
                    column: :member_user_id,
                    on_delete: :cascade
  end
end
