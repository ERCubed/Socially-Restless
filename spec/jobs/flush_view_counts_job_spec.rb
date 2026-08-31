require "rails_helper"

RSpec.describe FlushViewCountsJob do
  it_behaves_like "a recurring job"

  describe "#perform" do
    it "applies pending view counts to Postgres for multiple posts in one batch" do
      post_a = create(:post, view_count: 10)
      post_b = create(:post, view_count: 0)
      ViewCounts.record([ post_a.id, post_a.id, post_b.id ]) # 2 views on a, 1 on b

      update_queries = []
      subscriber = ->(*, payload) { update_queries << payload[:sql] if payload[:sql].match?(/\AUPDATE "?posts"?/i) }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        described_class.perform_now
      end

      expect(update_queries.size).to eq(1) # one batched statement, not one per post
      expect(post_a.reload.view_count).to eq(12)
      expect(post_b.reload.view_count).to eq(1)
    end

    it "does nothing when there are no pending views" do
      expect_any_instance_of(ActiveRecord::ConnectionAdapters::AbstractAdapter)
        .not_to receive(:execute).with(a_string_matching(/UPDATE/i))

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
