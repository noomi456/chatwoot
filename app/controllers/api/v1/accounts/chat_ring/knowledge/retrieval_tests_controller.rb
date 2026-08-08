class Api::V1::Accounts::ChatRing::Knowledge::RetrievalTestsController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  def create
    authorize(ChatRing::KnowledgeMaterial, :index?)
    evidence_set = ChatRing::Knowledge::Retriever.preview(
      account: Current.account,
      query: params.require(:query),
      limit: params.fetch(:limit, ChatRing::Knowledge::DocsGptProvider::DEFAULT_EVIDENCE_LIMIT)
    )
    render json: serialize_evidence_set(evidence_set)
  rescue ChatRing::Knowledge::Retriever::Error => e
    render_unprocessable(e)
  end
end
