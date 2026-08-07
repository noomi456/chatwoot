class ChatRing::KnowledgeVersionPolicy < ApplicationPolicy
  def index?
    account_user.administrator?
  end

  def show?
    account_user.administrator?
  end

  def create?
    account_user.administrator?
  end

  def evaluate?
    account_user.administrator?
  end

  def publish?
    account_user.administrator?
  end

  def rollback?
    account_user.administrator?
  end

  def retrieve?
    account_user.administrator?
  end
end
