class Api::V1::Accounts::ChatRing::InboxPlaybooksController < Api::V1::Accounts::ChatRing::AssistantManagementBaseController
  before_action :playbook, except: [:index, :create]

  def index
    authorize(ChatRing::Assistant, :index?)
    playbooks = workspace.inbox_playbooks.where(chatwoot_inbox_id: Current.account.inbox_ids)
                         .includes(:inbox, :current_version)
                         .order(:chatwoot_inbox_id, :name)
    playbooks = playbooks.where(chatwoot_inbox_id: params[:inbox_id]) if params[:inbox_id].present?
    render json: playbooks.map { |item| serialize_playbook(item) }
  end

  def show
    authorize(@playbook.inbox, :update?)
    render json: serialize_playbook(@playbook)
  end

  def create
    inbox = Current.account.inboxes.find(create_params.require(:inbox_id))
    authorize(inbox, :update?)
    item = workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: Current.user,
      name: create_params.require(:name).strip,
      purpose: create_params[:purpose].to_s.strip,
      draft_definition: default_definition
    )
    render json: serialize_playbook(item), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e)
  end

  def update_draft
    authorize(@playbook.inbox, :update?)
    source = draft_params
    item = ChatRing::Playbooks::DraftUpdater.new(
      playbook: @playbook,
      expected_lock_version: source.require(:lock_version),
      attributes: {
        name: source.require(:name).strip,
        purpose: source[:purpose].to_s.strip,
        draft_definition: definition_from(source)
      }
    ).call
    render json: serialize_playbook(item)
  rescue ChatRing::Playbooks::DraftUpdater::InvalidRevision => e
    render json: { error: e.message, code: 'stale_playbook' }, status: :conflict
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    render_unprocessable(e)
  end

  def validate
    authorize(@playbook.inbox, :update?)
    result = ChatRing::Playbooks::DefinitionValidator.new(playbook: @playbook, definition: definition_from(params)).call
    render json: result.as_json
  end

  def publish
    authorize(@playbook.inbox, :update?)
    version = ChatRing::Playbooks::Publisher.new(
      playbook: @playbook,
      actor: Current.user,
      expected_lock_version: params.require(:lock_version)
    ).call
    render json: { playbook: serialize_playbook(@playbook.reload), version: serialize_version(version) }
  rescue ChatRing::Playbooks::Publisher::InvalidRevision => e
    render json: { error: e.message, code: 'stale_playbook' }, status: :conflict
  rescue ChatRing::Playbooks::Publisher::InvalidDefinition => e
    render json: e.result.as_json, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    render_unprocessable(e)
  end

  def disable
    authorize(@playbook.inbox, :update?)
    mutate_status!(:disabled)
  end

  def archive
    authorize(@playbook.inbox, :update?)
    mutate_status!(:archived)
  end

  private

  def playbook
    @playbook = workspace.inbox_playbooks.includes(:inbox, :current_version).find(params[:id])
  end

  def create_params
    params.require(:playbook).permit(:inbox_id, :name, :purpose)
  end

  def draft_params
    params.require(:playbook).permit(:lock_version, :name, :purpose, definition: {})
  end

  def definition_from(source)
    value = source[:definition]
    value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h
  end

  def default_definition
    {
      'trigger_phrases' => [],
      'entry_step_id' => '',
      'steps' => [],
      'collected_fields' => [],
      'tool_allowlist' => [],
      'safety_rules' => {
        'on_human_request' => 'native_availability',
        'on_side_question' => 'answer_then_resume'
      }
    }
  end

  def mutate_status!(status)
    expected_lock_version = Integer(params.require(:lock_version))
    item = Account.transaction do
      Account.lock.find(workspace.chatwoot_account_id)
      Inbox.lock.find(@playbook.chatwoot_inbox_id)
      locked = ChatRing::InboxPlaybook.lock.find(@playbook.id)
      unless locked.lock_version == expected_lock_version
        raise ChatRing::Playbooks::DraftUpdater::InvalidRevision, 'Inbox Playbook changed; reload before updating'
      end
      if locked.archived? && status != :archived
        raise ChatRing::Playbooks::DraftUpdater::InvalidRevision, 'Archived Inbox Playbooks cannot be reactivated'
      end

      locked.update!(status: status)
      locked
    end
    render json: serialize_playbook(item)
  rescue ChatRing::Playbooks::DraftUpdater::InvalidRevision => e
    render json: { error: e.message, code: 'stale_playbook' }, status: :conflict
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e)
  end

  def serialize_playbook(item)
    {
      id: item.id,
      name: item.name,
      purpose: item.purpose,
      status: item.status,
      lock_version: item.lock_version,
      inbox: { id: item.inbox.id, name: item.inbox.name, channel_type: item.inbox.channel_type },
      draft_definition: item.draft_definition,
      current_version: serialize_version(item.current_version),
      created_at: item.created_at,
      updated_at: item.updated_at
    }
  end

  def serialize_version(version)
    return unless version

    {
      id: version.id,
      version: version.version,
      name: version.name,
      purpose: version.purpose,
      definition: version.definition,
      capability_snapshot: version.capability_snapshot,
      validation_result: version.validation_result,
      published_at: version.published_at
    }
  end
end
