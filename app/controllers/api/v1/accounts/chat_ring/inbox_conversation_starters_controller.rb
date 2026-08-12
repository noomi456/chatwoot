class Api::V1::Accounts::ChatRing::InboxConversationStartersController < Api::V1::Accounts::ChatRing::AssistantManagementBaseController
  before_action :inbox, only: [:update]

  def index
    configurations = ChatRing::InboxConversationStarter
                     .where(workspace: workspace, chatwoot_inbox_id: website_inboxes.select(:id))
                     .index_by(&:chatwoot_inbox_id)
    render json: website_inboxes.order(:name).map { |item| serialize(item, configurations[item.id]) }
  end

  def update
    authorize(@inbox, :update?)
    configuration = ChatRing::ConversationStarters::ConfigurationPublisher.new(
      workspace: workspace,
      inbox: @inbox,
      actor: Current.user,
      attributes: configuration_attributes
    ).call
    render json: serialize(@inbox, configuration)
  rescue ChatRing::ConversationStarters::ConfigurationPublisher::InvalidRevision => e
    render json: { error: e.message, code: 'stale_conversation_starter_configuration' }, status: :conflict
  rescue ActiveRecord::RecordInvalid, KeyError, ArgumentError => e
    render_unprocessable(e)
  end

  private

  def website_inboxes
    Current.account.inboxes.includes(:channel).where(channel_type: 'Channel::WebWidget')
  end

  def inbox
    @inbox = website_inboxes.find(params[:inbox_id])
  end

  def configuration_attributes
    source = params.require(:conversation_starters)
    {
      lock_version: source.require(:lock_version),
      enabled: source.require(:enabled),
      starters: starter_attributes(source)
    }
  end

  def starter_attributes(source)
    raise ActionController::ParameterMissing, :starters unless source.key?(:starters)

    starters = source[:starters]
    raise ArgumentError, 'starters must be an array' unless starters.is_a?(Array)

    starters.map do |starter|
      raise ArgumentError, 'each starter must be an object' unless starter.is_a?(ActionController::Parameters)

      unknown_keys = starter.keys - ChatRing::InboxConversationStarter::STARTER_KEYS
      raise ArgumentError, "unknown starter settings: #{unknown_keys.join(', ')}" if unknown_keys.present?

      starter.permit(:label, :prompt).to_h
    end
  end

  def serialize(item, configuration)
    {
      inbox: { id: item.id, name: item.name, channel_type: item.channel_type },
      id: configuration&.id,
      enabled: configuration&.enabled? || false,
      starters: configuration&.starters || [],
      lock_version: configuration&.lock_version || 0,
      updated_at: configuration&.updated_at
    }
  end
end
