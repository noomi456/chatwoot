class Api::V1::Accounts::Integrations::HooksController < Api::V1::Accounts::Integrations::BaseController
  before_action :fetch_hook, except: [:create]
  before_action :check_authorization

  def create
    attributes = permitted_params
    return @hook = Current.account.hooks.create!(attributes) unless enabled_dialogflow?(attributes)

    inbox = Current.account.inboxes.find(attributes[:inbox_id])
    inbox.with_lock do
      ensure_no_chatring_binding!(inbox)
      @hook = Current.account.hooks.create!(attributes)
    end
  end

  def update
    attributes = permitted_params.slice(:status, :settings)
    return @hook.update!(attributes) unless enabled_dialogflow?(attributes, hook: @hook)

    @hook.inbox.with_lock do
      ensure_no_chatring_binding!(@hook.inbox)
      @hook.update!(attributes)
    end
  end

  def process_event
    response = @hook.process_event(params[:event])

    # for cases like an invalid event, or when conversation does not have enough messages
    # for a label suggestion, the response is nil
    if response.nil?
      render json: { message: nil }
    elsif response[:error]
      render json: { error: response[:error] }, status: :unprocessable_entity
    else
      render json: { message: response[:message] }
    end
  end

  def destroy
    @hook.destroy!
    head :ok
  end

  private

  def fetch_hook
    @hook = Current.account.hooks.find(params[:id])
  end

  def permitted_params
    params.require(:hook).permit(:app_id, :inbox_id, :status, settings: {})
  end

  def enabled_dialogflow?(attributes, hook: nil)
    app_id = hook&.app_id || attributes[:app_id]
    status = attributes[:status].presence || hook&.status || 'enabled'
    app_id == 'dialogflow' && status.to_s == 'enabled'
  end

  def ensure_no_chatring_binding!(inbox)
    return unless ChatRing::InboxAssistantBinding.active.exists?(chatwoot_inbox_id: inbox.id)

    inbox.errors.add(:base, 'ChatRing Assistant owns this Inbox automation')
    raise ActiveRecord::RecordInvalid, inbox
  end
end
