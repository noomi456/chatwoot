class ChatRing::Workspace < ApplicationRecord
  self.table_name = 'chat_ring_workspaces'

  STATUSES = %w[active suspended disabled].freeze

  belongs_to :chatwoot_account,
             class_name: 'Account',
             inverse_of: :chat_ring_workspace
  has_many :webhook_deliveries,
           class_name: 'ChatRing::WebhookDelivery',
           inverse_of: :workspace,
           dependent: :destroy
  has_many :ai_turns,
           class_name: 'ChatRing::AiTurn',
           inverse_of: :workspace,
           dependent: :destroy
  has_one :knowledge_base,
          class_name: 'ChatRing::KnowledgeBase',
          inverse_of: :workspace,
          dependent: :destroy
  has_many :assistants,
           class_name: 'ChatRing::Assistant',
           inverse_of: :workspace,
           dependent: :destroy
  has_many :assistant_agent_bot_connections,
           class_name: 'ChatRing::AssistantAgentBotConnection',
           inverse_of: :workspace,
           dependent: :destroy
  has_many :inbox_assistant_bindings,
           class_name: 'ChatRing::InboxAssistantBinding',
           inverse_of: :workspace,
           dependent: :destroy
  has_many :inbox_tool_policies,
           class_name: 'ChatRing::InboxToolPolicy',
           inverse_of: :workspace,
           dependent: :destroy
  has_many :inbox_playbooks,
           class_name: 'ChatRing::InboxPlaybook',
           inverse_of: :workspace,
           dependent: :destroy
  has_many :knowledge_scopes,
           class_name: 'ChatRing::KnowledgeScope',
           inverse_of: :workspace,
           dependent: :destroy
  before_destroy :destroy_ai_turns_before_knowledge_indexes, prepend: true

  validates :chatwoot_account_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.for_account!(account)
    find_or_create_by!(chatwoot_account_id: account.id)
  end

  private

  # Turns retain immutable references to the knowledge index and evidence used.
  # Remove those runtime records before the KnowledgeBase destroys its indexes.
  def destroy_ai_turns_before_knowledge_indexes
    ChatRing::AiTurn.where(workspace_id: id).delete_all
    knowledge_base&.knowledge_indexes&.each do |index|
      index.association(:ai_turns).reset
      index.association(:ai_turn_evidence).reset
    end
  end
end
