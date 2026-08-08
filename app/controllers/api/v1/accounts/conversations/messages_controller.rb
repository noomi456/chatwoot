class Api::V1::Accounts::Conversations::MessagesController < Api::V1::Accounts::Conversations::BaseController
  before_action :ensure_api_inbox, only: :update

  def index
    @messages = message_finder.perform
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def conditional_create
    return head :not_found unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY

    result = Conversations::AgentBotConditionalCommitService.new(
      conversation: @conversation,
      agent_bot: @resource,
      expected_agent_bot_id: conditional_params[:expected_agent_bot_id],
      responding_to_message_id: conditional_params[:responding_to_message_id],
      idempotency_key: conditional_params[:idempotency_key],
      message: conditional_params.require(:message)
    ).perform
    render json: conditional_response(result), status: :ok
  rescue Conversations::AgentBotConditionalCommitService::Unauthorized
    head :forbidden
  rescue Conversations::AgentBotConditionalCommitService::PreconditionFailed => e
    render json: { error: e.code }, status: :conflict
  end

  def update
    Messages::StatusUpdateService.new(message, permitted_params[:status], permitted_params[:external_error]).perform
    @message = message
  end

  def destroy
    ActiveRecord::Base.transaction do
      message.update!(content: I18n.t('conversations.messages.deleted'), content_type: :text, content_attributes: { deleted: true })
      message.attachments.destroy_all
    end
  end

  def retry
    return if message.blank?

    service = Messages::StatusUpdateService.new(message, 'sent')
    service.perform
    message.update!(content_attributes: {})
    ::SendReplyJob.perform_later(message.id)
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def translate
    return head :ok if already_translated_content_available?

    translated_content = Integrations::GoogleTranslate::ProcessorService.new(
      message: message,
      target_language: permitted_params[:target_language]
    ).perform

    if translated_content.present?
      translations = {}
      translations[permitted_params[:target_language]] = translated_content
      translations = message.translations.merge!(translations) if message.translations.present?
      message.update!(translations: translations)
    end

    render json: { content: translated_content }
  rescue Google::Cloud::Error => e
    # `details` carries the clean human message; `message` includes gRPC debug noise
    render_could_not_create_error(e.details.presence || e.message)
  end

  private

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params)
  end

  def permitted_params
    params.permit(:id, :target_language, :status, :external_error)
  end

  def conditional_params
    params.permit(:expected_agent_bot_id, :responding_to_message_id, :idempotency_key, message: [:content, :content_type])
  end

  def conditional_response(result)
    {
      message_id: result.message.id,
      idempotent: result.idempotent,
      conversation_status: @conversation.reload.status,
      assignee_agent_bot_id: @conversation.assignee_agent_bot_id
    }
  end

  def already_translated_content_available?
    message.translations.present? && message.translations[permitted_params[:target_language]].present?
  end

  # API inbox check
  def ensure_api_inbox
    # Only API inboxes can update messages
    render json: { error: 'Message status update is only allowed for API inboxes' }, status: :forbidden unless @conversation.inbox.api?
  end
end
