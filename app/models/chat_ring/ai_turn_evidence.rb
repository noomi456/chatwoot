class ChatRing::AiTurnEvidence < ApplicationRecord
  self.table_name = 'chat_ring_ai_turn_evidence'

  belongs_to :ai_turn, class_name: 'ChatRing::AiTurn', inverse_of: :evidence
  belongs_to :knowledge_index, class_name: 'ChatRing::KnowledgeIndex', optional: true

  validates :position, :rank, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :evidence_id, :source_kind, :source_reference, :source_title,
            :excerpt, :source_content_hash, presence: true
  validates :position, uniqueness: { scope: :ai_turn_id }

  attr_readonly :ai_turn_id,
                :position,
                :evidence_id,
                :knowledge_index_id,
                :provider_source_id,
                :provider_chunk_id,
                :source_kind,
                :source_reference,
                :source_title,
                :public_url,
                :heading_path,
                :excerpt,
                :source_content_hash,
                :rank,
                :score,
                :metadata
end
