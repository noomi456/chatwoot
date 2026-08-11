class Api::V1::Accounts::ChatRing::AssistantsController < Api::V1::Accounts::ChatRing::AssistantManagementBaseController
  before_action :assistant, except: [:index, :create]

  def index
    authorize(ChatRing::Assistant, :index?)
    assistants = workspace.assistants.includes(:current_version, :configuration_draft, :agent_bot_connection, :inbox_bindings).order(:name)
    render json: assistants.map { |item| serialize_assistant(item) }
  end

  def show
    authorize(@assistant)
    render json: serialize_assistant(@assistant, include_draft: true)
  end

  def create
    authorize(ChatRing::Assistant, :create?)
    assistant = ChatRing::Assistant.transaction do
      created = workspace.assistants.create!(name: create_params.require(:name).strip)
      created.create_configuration_draft!(
        knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
        handoff_policy: default_handoff_policy
      )
      created
    end
    render json: serialize_assistant(assistant, include_draft: true), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e)
  end

  def update_draft
    authorize(@assistant, :update?)
    ensure_mutable_assistant!
    update_assistant_draft!
    render json: serialize_assistant(@assistant.reload, include_draft: true)
  rescue ActiveRecord::RecordInvalid => e
    render_unprocessable(e)
  rescue ChatRing::AssistantManagement::DraftUpdater::InvalidRevision => e
    render json: { error: e.message }, status: :bad_request
  rescue ActiveRecord::StaleObjectError => e
    render json: { error: e.message }, status: :conflict
  end

  def publish
    authorize(@assistant, :update?)
    version = ChatRing::AssistantManagement::Publisher.new(
      assistant: @assistant,
      expected_lock_version: params.require(:lock_version)
    ).call
    render json: { assistant: serialize_assistant(@assistant.reload, include_draft: true), version: serialize_assistant_version(version) }
  rescue ActiveRecord::RecordInvalid, ChatRing::AssistantManagement::Publisher::InvalidRevision => e
    render_unprocessable(e)
  rescue ActiveRecord::StaleObjectError => e
    render json: { error: e.message }, status: :conflict
  end

  def archive
    authorize(@assistant, :destroy?)
    ChatRing::AssistantProvisioning::AssistantArchiver.new(assistant: @assistant).call
    render json: serialize_assistant(@assistant.reload, include_draft: true)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    render_unprocessable(e)
  end

  def binding_preflight
    authorize(@assistant, :update?)
    result = ChatRing::AssistantManagement::InboxBindingPreflight.new(assistant: @assistant, inbox: requested_inbox).call
    conflicts = result.conflicts.dup
    conflicts << release_gate_conflict unless public_ai_release_ready?
    render json: {
      ready: result.ready && public_ai_release_ready?,
      conflicts: conflicts,
      current_binding: result.current_binding && serialize_binding(result.current_binding),
      impact: result.impact
    }
  end

  def bind
    authorize(@assistant, :update?)
    ensure_mutable_assistant!
    return render_release_gate_closed unless public_ai_release_ready?

    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: @assistant, inbox: requested_inbox).call
    render json: serialize_binding(binding), status: :created
  rescue ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError => e
    render json: { error: e.message, code: 'inbox_conflict' }, status: :conflict
  rescue ActiveRecord::RecordInvalid,
         ActiveRecord::RecordNotSaved,
         ChatRing::AssistantProvisioning::AgentBotConnector::OwnershipError => e
    render_unprocessable(e)
  end

  def rotate_managed_secret
    authorize(@assistant, :update?)
    ensure_mutable_assistant!
    connection = ChatRing::AssistantManagement::ManagedSecretRotator.new(assistant: @assistant).call
    render json: { rotated: true, last_verified_at: connection.last_verified_at }
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid => e
    render_unprocessable(e)
  end

  private

  def assistant
    @assistant = workspace.assistants.find(params[:id])
  end

  def requested_inbox
    @requested_inbox ||= Current.account.inboxes.find(params.require(:inbox_id))
  end

  def create_params
    params.require(:assistant).permit(:name)
  end

  def draft_params
    params.require(:draft).permit(
      :name,
      :knowledge_scope_id,
      :lock_version,
      :instructions,
      identity: {},
      goals: [],
      response_guidelines: [],
      guardrails: [],
      tool_grants: [:key, :version],
      handoff_policy: {}
    )
  end

  def update_assistant_draft!
    attributes = draft_params.to_h.symbolize_keys
    requested_lock_version = attributes.delete(:lock_version)
    raise ActionController::ParameterMissing, :lock_version if requested_lock_version.nil?

    attributes[:knowledge_scope] = knowledge_scope(attributes.delete(:knowledge_scope_id)) if attributes.key?(:knowledge_scope_id)
    ChatRing::AssistantManagement::DraftUpdater.new(
      assistant: @assistant,
      expected_lock_version: requested_lock_version,
      attributes: attributes
    ).call
  end

  def knowledge_scope(id)
    workspace.knowledge_scopes.find(id)
  end

  def default_handoff_policy
    {
      'on_insufficient_evidence' => 'handoff',
      'on_provider_failure' => 'handoff'
    }
  end

  def public_ai_release_ready?
    ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
  end

  def release_gate_conflict
    { kind: 'public_ai_release_closed', record_id: nil, blocking: true }
  end

  def render_release_gate_closed
    render json: {
      error: 'Public AI release gate is closed',
      code: 'public_ai_release_closed'
    }, status: :conflict
  end

  def ensure_mutable_assistant!
    return unless @assistant.archived?

    @assistant.errors.add(:base, 'archived Assistant is read-only')
    raise ActiveRecord::RecordInvalid, @assistant
  end
end
