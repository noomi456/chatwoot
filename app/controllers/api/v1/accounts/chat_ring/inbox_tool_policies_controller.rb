class Api::V1::Accounts::ChatRing::InboxToolPoliciesController < Api::V1::Accounts::ChatRing::AssistantManagementBaseController
  before_action :inbox, except: [:index, :definitions]

  def index
    policies = ChatRing::InboxToolPolicy.where(workspace: workspace, chatwoot_inbox_id: Current.account.inbox_ids)
                                        .includes(:current_version)
                                        .index_by(&:chatwoot_inbox_id)
    render json: Current.account.inboxes.includes(:channel).order(:name).map do |item|
      serialize_policy(item, policies[item.id])
    end
  end

  def show
    authorize(@inbox, :update?)
    render json: serialize_policy(@inbox, policy)
  end

  def update
    authorize(@inbox, :update?)
    attributes = policy_attributes
    version = ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: @inbox,
      actor: Current.user,
      expected_lock_version: attributes.fetch(:lock_version),
      enabled_tools: attributes.fetch(:enabled_tools),
      tool_configurations: attributes.fetch(:tool_configurations),
      renderer_policy: {}
    ).call
    render json: serialize_policy(@inbox, version.inbox_tool_policy.reload)
  rescue ChatRing::Tools::PolicyPublisher::InvalidRevision => e
    render json: { error: e.message, code: 'stale_tool_policy' }, status: :conflict
  rescue ActiveRecord::RecordInvalid, KeyError, ArgumentError => e
    render_unprocessable(e)
  end

  def definitions
    authorize(ChatRing::Assistant, :index?)
    render json: ChatRing::Tools::Registry.all.map(&:as_json)
  end

  private

  def inbox
    @inbox = Current.account.inboxes.includes(:channel).find(params[:inbox_id])
  end

  def policy
    ChatRing::InboxToolPolicy.includes(:current_version).find_by(workspace: workspace, chatwoot_inbox_id: @inbox.id)
  end

  def policy_attributes
    source = params.require(:tool_policy)
    {
      lock_version: source.require(:lock_version),
      enabled_tools: Array.wrap(source[:enabled_tools]).map { |item| item.permit(:key, :version).to_h },
      tool_configurations: appointment_configuration(source)
    }
  end

  def appointment_configuration(source)
    appointment = source.dig(:tool_configurations, :request_appointment)
    return {} unless appointment

    allowed_keys = %w[provider url fallback_mode link_label]
    unknown_keys = appointment.keys - allowed_keys
    raise ArgumentError, "unknown request_appointment settings: #{unknown_keys.join(', ')}" if unknown_keys.present?

    { 'request_appointment' => appointment.permit(*allowed_keys).to_h }
  end

  def serialize_policy(item, item_policy)
    version = item_policy&.current_version
    capabilities = version ? ChatRing::Tools::InboxCapabilityProfile.new(inbox: item, policy_version: version).capabilities : []
    {
      inbox: {
        id: item.id,
        name: item.name,
        channel_type: item.channel_type
      },
      id: item_policy&.id,
      status: item_policy&.status || 'unconfigured',
      lock_version: item_policy&.lock_version || 0,
      current_version: serialize_version(version),
      capabilities: capabilities.map(&:as_json)
    }
  end

  def serialize_version(version)
    return unless version

    {
      id: version.id,
      version: version.version,
      enabled_tools: version.enabled_tools,
      tool_configurations: version.tool_configurations,
      renderer_policy: version.renderer_policy,
      published_at: version.published_at
    }
  end
end
