class Api::V1::Accounts::ChatRing::Knowledge::BaseController < Api::V1::Accounts::BaseController
  include ::ChatRing::KnowledgeManagementSerialization

  before_action :check_admin_authorization?

  private

  def inbox
    @inbox ||= Current.account.inboxes.find(params.require(:inbox_id))
  end

  def render_unprocessable(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
