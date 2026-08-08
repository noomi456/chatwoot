class Api::V1::Accounts::ChatRing::Knowledge::FileSourcesController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  def create
    authorize(ChatRing::KnowledgeFileSource, :create?)
    result = ChatRing::Knowledge::FileSourceService.create!(
      account: Current.account,
      uploaded_file: params.require(:file),
      authority_class: params.fetch(:authority_class, 'product_documentation'),
      actor: Current.user
    )
    render json: serialize_file_source(result.source).merge(reused: result.reused),
           status: result.reused ? :ok : :accepted
  rescue ChatRing::Knowledge::FileSourceService::Error, ChatRing::Knowledge::FilePreflight::Error => e
    render_unprocessable(e)
  end
end
