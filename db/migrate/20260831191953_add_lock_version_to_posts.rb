class AddLockVersionToPosts < ActiveRecord::Migration[8.1]
  def change
    # `lock_version` is the exact column name ActiveRecord::Locking::Optimistic
    # looks for - no model code needed to opt in, it activates automatically.
    add_column :posts, :lock_version, :integer, null: false, default: 0
  end
end
