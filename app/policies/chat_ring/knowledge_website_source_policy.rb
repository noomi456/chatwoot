class ChatRing::KnowledgeWebsiteSourcePolicy < ApplicationPolicy
  def create?
    account_user.administrator?
  end
end
