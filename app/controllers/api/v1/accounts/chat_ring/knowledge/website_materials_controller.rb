class Api::V1::Accounts::ChatRing::Knowledge::WebsiteMaterialsController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  def destroy
    authorize(ChatRing::KnowledgeVersion, :create?)
    version = scoped_versions.includes(:documents).find(params.require(:version_id))
    document = version.documents.where(source_kind: 'website').find(params[:id])
    file_sources = ChatRing::KnowledgeFileSource.where(account: Current.account, inbox: inbox).available.ready.order(:id)

    created = ChatRing::Knowledge::VersionComposer.compose!(
      account: Current.account,
      inbox: inbox,
      base_version: version,
      file_sources: file_sources,
      publish_on_ready: true,
      excluded_website_references: [document.source_reference]
    )
    render json: serialize_version(created), status: :accepted
  rescue ChatRing::Knowledge::VersionComposer::Error => e
    render_unprocessable(e)
  end

  private

  def scoped_versions
    ChatRing::KnowledgeVersion.where(account: Current.account, inbox: inbox)
  end
end
