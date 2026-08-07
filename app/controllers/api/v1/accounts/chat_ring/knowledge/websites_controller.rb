class Api::V1::Accounts::ChatRing::Knowledge::WebsitesController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  def create
    authorize(ChatRing::KnowledgeVersion, :create?)
    version = ChatRing::Knowledge::SyncService.start!(
      account: Current.account,
      inbox: inbox,
      root_url: params.require(:root_url)
    )
    render json: serialize_version(version), status: :accepted
  rescue ArgumentError, ChatRing::Knowledge::FirecrawlClient::Error => e
    render_unprocessable(e)
  end
end
