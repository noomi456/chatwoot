class Api::V1::Accounts::ChatRing::Knowledge::VersionsController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  before_action :version, only: [:show, :evaluate, :publish]

  def index
    authorize(ChatRing::KnowledgeVersion, :index?)
    versions = ChatRing::KnowledgeVersion.includes(:documents).where(account: Current.account, inbox: inbox).order(created_at: :desc)
    publication = ChatRing::KnowledgePublication.find_by(account: Current.account, inbox: inbox)
    render json: {
      published_version_id: publication&.knowledge_version_id,
      rollback_version_id: publication&.previous_knowledge_version_id,
      versions: versions.map { |item| serialize_version(item) }
    }
  end

  def show
    authorize(@version)
    render json: serialize_version(@version, include_documents: true)
  end

  def create
    authorize(ChatRing::KnowledgeVersion, :create?)
    base_version = selected_base_version
    file_sources = selected_file_sources
    created = ChatRing::Knowledge::VersionComposer.compose!(
      account: Current.account,
      inbox: inbox,
      base_version: base_version,
      file_sources: file_sources,
      publish_on_ready: true
    )
    render json: serialize_version(created), status: :accepted
  rescue ChatRing::Knowledge::VersionComposer::Error => e
    render_unprocessable(e)
  end

  def evaluate
    authorize(@version, :evaluate?)
    report = ChatRing::Knowledge::EvaluationService.evaluate!(@version, cases: params.require(:cases))
    render json: report
  rescue ChatRing::Knowledge::EvaluationService::Error => e
    render_unprocessable(e)
  end

  def publish
    authorize(@version, :publish?)
    publication = ChatRing::Knowledge::PublicationService.publish!(@version, actor: Current.user)
    render json: {
      published_version_id: publication.knowledge_version_id,
      rollback_version_id: publication.previous_knowledge_version_id
    }
  rescue ChatRing::Knowledge::PublicationService::Error, ChatRing::Knowledge::ProviderValidator::Error => e
    render_unprocessable(e)
  end

  private

  def version
    @version = scoped_versions.includes(:documents).find(params[:id])
  end

  def scoped_versions
    ChatRing::KnowledgeVersion.where(account: Current.account, inbox: inbox)
  end

  def scoped_file_sources
    ChatRing::KnowledgeFileSource.where(account: Current.account, inbox: inbox)
  end

  def selected_base_version
    return scoped_versions.find(params[:base_version_id]) if params[:base_version_id].present?

    scoped_versions.where.not(root_url: nil).where(status: %w[ready published retired]).order(created_at: :desc).first
  end

  def selected_file_sources
    if params.key?(:file_source_ids)
      raise ChatRing::Knowledge::VersionComposer::Error,
            'Knowledge builds always include every enabled ready file; disable a source explicitly before excluding it'
    end

    scoped_file_sources.available.ready.order(:id).to_a
  end
end
