class Api::V1::Accounts::ChatRing::Knowledge::WebsitesController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  # Adding a complete website is one user command: Map filters unsuitable
  # routes, then the remaining pages are queued for exact extraction.
  def create
    authorize(ChatRing::KnowledgeWebsiteSource, :create?)
    source = ChatRing::Knowledge::WebsiteSourceService.add_website!(
      account: Current.account,
      root_url: params.require(:root_url),
      actor: Current.user
    )
    render json: { id: source.id, status: source.status }, status: :accepted
  rescue ChatRing::Knowledge::WebsiteSourceService::Error, ChatRing::Knowledge::FirecrawlClient::Error => e
    render_unprocessable(e)
  end
end
