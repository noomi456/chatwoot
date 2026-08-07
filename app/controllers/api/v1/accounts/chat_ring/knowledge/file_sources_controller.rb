class Api::V1::Accounts::ChatRing::Knowledge::FileSourcesController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  before_action :file_source, only: [:show, :update, :destroy, :retry_parse, :enable, :purge]

  def index
    authorize(ChatRing::KnowledgeFileSource, :index?)
    sources = ChatRing::KnowledgeFileSource.where(account: Current.account, inbox: inbox).order(created_at: :desc)
    render json: sources.map { |source| serialize_file_source(source) }
  end

  def show
    authorize(@file_source)
    render json: serialize_file_source(@file_source, include_content: true)
  end

  def create
    authorize(ChatRing::KnowledgeFileSource, :create?)
    result = ChatRing::Knowledge::FileSourceService.create!(
      account: Current.account,
      inbox: inbox,
      uploaded_file: params.require(:file),
      authority_class: params.fetch(:authority_class, 'product_documentation'),
      actor: Current.user
    )
    render json: serialize_file_source(result.source).merge(reused: result.reused), status: result.reused ? :ok : :accepted
  rescue ChatRing::Knowledge::FileSourceService::Error, ChatRing::Knowledge::FilePreflight::Error => e
    render_unprocessable(e)
  end

  def update
    authorize(@file_source)
    @file_source.update!(
      authority_class: params.require(:authority_class),
      approved_by: Current.user
    )
    render json: serialize_file_source(@file_source)
  end

  def destroy
    authorize(@file_source)
    previous_status = @file_source.status
    @file_source.update!(status: 'disabled', disabled_at: Time.current)
    version = rebuild_without_disabled_source
    render json: serialize_file_source(@file_source).merge(knowledge_version_id: version&.id)
  rescue ChatRing::Knowledge::VersionComposer::Error, ChatRing::Knowledge::PublicationService::Error => e
    @file_source.update!(status: previous_status, disabled_at: nil)
    render_unprocessable(e)
  end

  def retry_parse
    authorize(@file_source, :retry_parse?)
    ChatRing::Knowledge::FileParseService.retry!(@file_source)
    render json: serialize_file_source(@file_source), status: :accepted
  rescue ChatRing::Knowledge::FileParseService::Error => e
    render_unprocessable(e)
  end

  def enable
    authorize(@file_source, :enable?)
    raise ChatRing::Knowledge::FileParseService::Error, 'Only disabled file sources can be enabled' unless @file_source.status == 'disabled'

    @file_source.update!(status: @file_source.markdown.present? ? 'ready' : 'uploaded', disabled_at: nil)
    ChatRing::Knowledge::FileParseJob.perform_later(@file_source.id) if @file_source.status == 'uploaded'
    render json: serialize_file_source(@file_source)
  rescue ChatRing::Knowledge::FileParseService::Error => e
    render_unprocessable(e)
  end

  def purge
    authorize(@file_source, :destroy?)
    ChatRing::Knowledge::FileSourcePurgeService.call(@file_source)
    head :no_content
  rescue ChatRing::Knowledge::FileSourcePurgeService::Error => e
    render_unprocessable(e)
  end

  private

  def file_source
    @file_source = ChatRing::KnowledgeFileSource.find_by!(id: params[:id], account_id: Current.account.id)
    raise ActiveRecord::RecordNotFound unless @file_source.inbox_id == inbox.id
  end

  def rebuild_without_disabled_source
    publication = ChatRing::KnowledgePublication.find_by(account: Current.account, inbox: inbox)
    return unless publication

    ChatRing::Knowledge::VersionComposer.compose!(
      account: Current.account,
      inbox: inbox,
      base_version: publication.knowledge_version,
      file_sources: ChatRing::KnowledgeFileSource.where(account: Current.account, inbox: inbox).available.ready.order(:id),
      publish_on_ready: true
    )
  end
end
