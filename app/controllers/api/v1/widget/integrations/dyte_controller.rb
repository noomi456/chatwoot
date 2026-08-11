class Api::V1::Widget::Integrations::DyteController < Api::V1::Widget::BaseController
  before_action :set_message

  def add_participant_to_meeting
    unless visitor_visible_meeting_message?
      return render json: {
        error: I18n.t('errors.dyte.invalid_message_type')
      }, status: :unprocessable_entity
    end

    response = dyte_processor_service.add_participant_to_meeting(
      @message.content_attributes['data']['meeting_id'],
      @conversation.contact,
      @message
    )
    render_response(response)
  end

  private

  def render_response(response)
    render json: response, status: response[:error].blank? ? :ok : :unprocessable_entity
  end

  def dyte_processor_service
    Integrations::Dyte::ProcessorService.new(account: @web_widget.inbox.account, conversation: @conversation)
  end

  def visitor_visible_meeting_message?
    attributes = @message.content_attributes.with_indifferent_access

    @message.content_type == 'integrations' &&
      @message.outgoing? &&
      !@message.private? &&
      attributes[:type] == 'dyte' &&
      attributes[:data].is_a?(Hash) &&
      attributes.dig(:data, :meeting_id).present?
  end

  def set_message
    @conversation = conversations.joins(:messages).find_by!(messages: { id: permitted_params[:message_id] })
    @message = @conversation.messages.find(permitted_params[:message_id])
  end

  def permitted_params
    params.permit(:website_token, :message_id)
  end
end
