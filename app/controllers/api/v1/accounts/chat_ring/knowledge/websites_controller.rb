class Api::V1::Accounts::ChatRing::Knowledge::WebsitesController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  before_action :website_source, only: [:show, :extract]

  def index
    authorize(ChatRing::KnowledgeWebsiteSource, :index?)
    render json: knowledge_base.website_sources.visible.order(created_at: :desc).map { |source| serialize_website_source(source) }
  end

  def show
    authorize(@website_source)
    render json: serialize_website_source(@website_source)
  end

  # The user enters a URL. This maps it and returns the pre-filtered page list;
  # no webpage is extracted until the user selects pages and calls extract.
  def create
    authorize(ChatRing::KnowledgeWebsiteSource, :create?)
    source = ChatRing::Knowledge::WebsiteSourceService.map!(
      account: Current.account,
      root_url: params.require(:root_url),
      actor: Current.user
    )
    render json: serialize_website_source(source), status: :created
  rescue ChatRing::Knowledge::WebsiteSourceService::Error, ChatRing::Knowledge::FirecrawlClient::Error => e
    render_unprocessable(e)
  end

  # This is the user's Add action after reviewing the mapped page list.
  def extract
    authorize(@website_source, :update?)
    ChatRing::Knowledge::WebsiteSourceService.extract!(
      source: @website_source,
      selected_urls: params.require(:selected_urls)
    )
    render json: serialize_website_source(@website_source), status: :accepted
  rescue ChatRing::Knowledge::WebsiteSourceService::Error => e
    render_unprocessable(e)
  end

  private

  def website_source
    @website_source = knowledge_base.website_sources.find(params[:id])
  end
end
