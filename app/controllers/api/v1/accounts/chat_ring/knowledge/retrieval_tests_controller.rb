class Api::V1::Accounts::ChatRing::Knowledge::RetrievalTestsController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  def create
    authorize(ChatRing::KnowledgeVersion, :retrieve?)
    version = ChatRing::KnowledgeVersion.includes(:documents).find_by!(
      id: params.require(:knowledge_version_id),
      account_id: Current.account.id,
      inbox_id: inbox.id
    )
    evidence_set = ChatRing::Knowledge::Retriever.preview(
      version: version,
      query: params.require(:query),
      limit: params.fetch(:limit, ChatRing::Knowledge::DocsGptProvider::DEFAULT_EVIDENCE_LIMIT)
    )
    render json: serialize_evidence_set(evidence_set)
  rescue ChatRing::Knowledge::Retriever::Error => e
    render_unprocessable(e)
  end
end
