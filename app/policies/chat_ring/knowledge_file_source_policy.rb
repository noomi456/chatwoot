class ChatRing::KnowledgeFileSourcePolicy < ApplicationPolicy
  def create?
    account_user.administrator?
  end
end
