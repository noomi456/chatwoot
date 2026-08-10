class Api::V1::Accounts::ChatRing::AssistantManagementBaseController < Api::V1::Accounts::BaseController
  include ::ChatRing::AssistantManagementSerialization
  include ::ChatRing::AiTurnManagementSerialization

  before_action :check_admin_authorization?

  private

  def workspace
    @workspace ||= ChatRing::Workspace.for_account!(Current.account)
  end

  def render_unprocessable(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
