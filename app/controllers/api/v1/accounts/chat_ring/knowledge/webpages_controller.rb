class Api::V1::Accounts::ChatRing::Knowledge::WebpagesController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  # A single page is scraped directly. This endpoint never invokes Firecrawl
  # Map and never discovers additional URLs.
  def create
    authorize(ChatRing::KnowledgeWebsiteSource, :create?)
    source = ChatRing::Knowledge::WebsiteSourceService.add_webpage!(
      account: Current.account,
      url: params.require(:url),
      actor: Current.user
    )
    render json: { id: source.id, status: source.status }, status: :accepted
  rescue ChatRing::Knowledge::WebsiteSourceService::Error, ChatRing::Knowledge::FirecrawlClient::Error => e
    render_unprocessable(e)
  end
end
