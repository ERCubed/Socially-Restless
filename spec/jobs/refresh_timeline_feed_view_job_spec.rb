require "rails_helper"

RSpec.describe RefreshTimelineFeedViewJob do
  it_behaves_like "a recurring job"

  describe "#perform" do
    it "refreshes the view so it reflects posts created since the last refresh" do
      post = create(:post, title: "Needs a refresh")

      described_class.perform_now

      expect(TimelineFeedEntry.find_by(id: post.id).title).to eq("Needs a refresh")
    end
  end
end
