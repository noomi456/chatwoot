class Api::V1::Accounts::ChatRing::AssistantBindingsController < Api::V1::Accounts::ChatRing::AssistantManagementBaseController
  def destroy
    binding = workspace.inbox_assistant_bindings.find(params[:id])
    authorize(binding)
    ChatRing::AssistantProvisioning::InboxBindingDeactivator.new(binding: binding).call
    head :no_content
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    render_unprocessable(e)
  end
end
