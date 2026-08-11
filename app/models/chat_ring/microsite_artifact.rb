class ChatRing::MicrositeArtifact < ApplicationRecord
  self.table_name = 'chat_ring_microsite_artifacts'

  CONTRACT_VERSION = 1
  DEFAULT_RETENTION = 7.days

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :microsite_artifacts
  belongs_to :ai_turn, class_name: 'ChatRing::AiTurn', inverse_of: :microsite_artifact
  belongs_to :message, class_name: 'Message', inverse_of: false, optional: true

  has_secure_token :public_token, length: 32

  scope :available, -> { where('expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at <= ?', Time.current) }

  validates :ai_turn_id, :public_token, uniqueness: true
  validates :contract_version, numericality: { only_integer: true, equal_to: CONTRACT_VERSION }
  validates :expires_at, presence: true
  validate :payload_contract
  validate :source_evidence_belongs_to_turn
  validate :native_scope_matches
  validate :message_link_is_write_once, on: :update

  attr_readonly :workspace_id, :ai_turn_id, :public_token, :contract_version,
                :content, :source_evidence_ids, :expires_at

  def available?
    expires_at.future?
  end

  private

  def payload_contract # rubocop:disable Metrics/CyclomaticComplexity
    errors.add(:content, 'must be an object') unless content.is_a?(Hash)
    errors.add(:source_evidence_ids, 'must be an array') unless source_evidence_ids.is_a?(Array)
    return unless content.is_a?(Hash)

    types = Array(content['sections']).filter_map { |section| section['type'] if section.is_a?(Hash) }
    ChatRing::Microsites::SectionContract.normalize_types(types)
    errors.add(:content, 'must contain one to three grounded sections') unless types.length.between?(1, 3)
  rescue ChatRing::Microsites::SectionContract::Invalid => e
    errors.add(:content, e.message)
  end

  def native_scope_matches
    return if workspace.blank? || ai_turn.blank?

    errors.add(:ai_turn, 'must belong to the selected Workspace') unless ai_turn.workspace_id == workspace_id
    return if message.blank? || message.conversation_id == ai_turn.chatwoot_conversation_id

    errors.add(:message, 'must belong to the AITurn Conversation')
  end

  def source_evidence_belongs_to_turn
    return unless source_evidence_ids.is_a?(Array) && ai_turn.present?

    ids = source_evidence_ids.map(&:to_s)
    unless ids.length.between?(1, 8) && ids.uniq.length == ids.length
      errors.add(:source_evidence_ids, 'must contain one to eight unique evidence IDs')
      return
    end
    return if ai_turn.evidence.where(evidence_id: ids).distinct.count(:evidence_id) == ids.length

    errors.add(:source_evidence_ids, 'must belong to the selected AITurn')
  end

  def message_link_is_write_once
    return unless will_save_change_to_message_id?
    return if message_id_in_database.nil? && message_id.present?

    errors.add(:message, 'can be linked only once')
  end
end
