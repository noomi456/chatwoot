class ChatRing::MicrositeCleanupJob < ApplicationJob
  queue_as :housekeeping

  def perform
    ChatRing::MicrositeArtifact.expired.in_batches(of: 500).delete_all
  end
end
