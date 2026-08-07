class ChatRing::KnowledgeFileSourcePolicy < ApplicationPolicy
  def index?
    account_user.administrator?
  end

  def show?
    account_user.administrator?
  end

  def create?
    account_user.administrator?
  end

  def update?
    account_user.administrator?
  end

  def destroy?
    account_user.administrator?
  end

  def retry_parse?
    account_user.administrator?
  end

  def enable?
    account_user.administrator?
  end
end
