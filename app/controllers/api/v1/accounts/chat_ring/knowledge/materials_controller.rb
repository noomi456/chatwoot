class Api::V1::Accounts::ChatRing::Knowledge::MaterialsController < Api::V1::Accounts::ChatRing::Knowledge::BaseController
  before_action :material, only: [:show, :destroy, :rerun]

  def index
    authorize(ChatRing::KnowledgeMaterial, :index?)
    materials = knowledge_base.materials.active.includes(:website_source, :file_source).order(updated_at: :desc)
    active_material_ids = knowledge_base.active_knowledge_index&.documents&.pluck(:knowledge_material_id).to_set || Set.new
    render json: materials.map do |item|
      serialize_material(item, available_to_ai: active_material_ids.include?(item.id))
    end
  end

  def show
    authorize(@material)
    render json: serialize_material(@material, include_content: true)
  end

  def destroy
    authorize(@material)
    ChatRing::Knowledge::MaterialService.delete!(@material)
    head :no_content
  end

  # The user chooses one row. Only that page/file is sent to Firecrawl again.
  def rerun
    authorize(@material, :update?)
    source = if @material.source_kind == 'website'
               ChatRing::Knowledge::WebsiteSourceService.rerun!(@material)
             else
               ChatRing::Knowledge::FileParseService.rerun!(@material.file_source)
             end
    render json: { material: serialize_material(@material), source_status: source.status }, status: :accepted
  rescue ChatRing::Knowledge::WebsiteSourceService::Error, ChatRing::Knowledge::FileParseService::Error => e
    render_unprocessable(e)
  end

  private

  def material
    @material = knowledge_base.materials.find(params[:id])
  end
end
