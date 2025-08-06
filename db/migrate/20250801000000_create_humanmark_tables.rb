# frozen_string_literal: true

class CreateHumanmarkTables < ActiveRecord::Migration[7.0]
  def change
    create_flows_table
    add_flows_indexes
    add_completed_challenge_constraint
  end

  def down
    drop_table :humanmark_flows
  end

  private

  def create_flows_table
    create_table :humanmark_flows do |t|
      # Core flow fields
      t.string :challenge, null: false
      t.text :token, null: false
      t.string :context, limit: 50, null: false
      t.bigint :user_id
      t.string :status, limit: 20, default: "pending"

      # Timestamps
      t.datetime :created_at, null: false
      t.datetime :completed_at

      # Optimistic locking
      t.integer :lock_version, default: 0, null: false
    end
  end

  def add_flows_indexes
    add_index :humanmark_flows, :challenge, unique: true
    add_index :humanmark_flows, %i[status created_at], name: "idx_humanmark_flows_status_created"
    add_index :humanmark_flows, :created_at

    # Index for reverify lookups
    add_index :humanmark_flows,
              %i[user_id context status completed_at],
              name: "idx_humanmark_flows_user_context_reverify",
              where: "status = 'completed'"
  end

  def add_completed_challenge_constraint
    execute <<-SQL
      CREATE UNIQUE INDEX idx_humanmark_flows_challenge_completed
      ON humanmark_flows(challenge)
      WHERE status = 'completed';
    SQL
  end
end
