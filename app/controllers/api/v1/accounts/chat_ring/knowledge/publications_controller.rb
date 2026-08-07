class Api::V1::Accounts::ChatRing::Knowledge::PublicationsController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  def show
    authorize(ChatRing::KnowledgeVersion, :index?)
    publication = ChatRing::KnowledgePublication.find_by(account: Current.account, inbox: inbox)
    render json: {
      published_version_id: publication&.knowledge_version_id,
      rollback_version_id: publication&.previous_knowledge_version_id,
      published_at: publication&.published_at
    }
  end

  def rollback
    authorize(ChatRing::KnowledgeVersion, :rollback?)
    publication = ChatRing::Knowledge::PublicationService.rollback!(
      account: Current.account,
      inbox: inbox,
      actor: Current.user
    )
    render json: {
      published_version_id: publication.knowledge_version_id,
      rollback_version_id: publication.previous_knowledge_version_id
    }
  rescue ChatRing::Knowledge::PublicationService::Error, ChatRing::Knowledge::ProviderValidator::Error => e
    render_unprocessable(e)
  end
end
