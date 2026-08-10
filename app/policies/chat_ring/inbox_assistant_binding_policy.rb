class ChatRing::InboxAssistantBindingPolicy < ApplicationPolicy
  def destroy?
    account_user.administrator?
  end
end
