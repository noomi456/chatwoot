require 'digest'

class ChatRing::Knowledge::IndexBuilder
  class Error < StandardError; end

  def self.enqueue!(knowledge_base)
    ChatRing::Knowledge::IndexBuildJob.perform_later(knowledge_base.id)
  end

  def self.build!(knowledge_base)
    new(knowledge_base).build!
  end

  def self.catalog_manifest(knowledge_base)
    knowledge_base.materials.retrievable.order(:id).map do |material|
      {
        'material_key' => material.material_key,
        'source_kind' => material.source_kind,
        'source_reference' => material.source_reference,
        'title' => material.title,
        'public_url' => material.public_url,
        'content_hash' => material.content_hash,
        'authority_class' => material.authority_class,
        'metadata' => material.metadata,
        'risk_flags' => material.risk_flags
      }.compact
    end
  end

  def self.catalog_digest(knowledge_base)
    Digest::SHA256.hexdigest(catalog_manifest(knowledge_base).to_json)
  end

  def initialize(knowledge_base)
    @knowledge_base = knowledge_base
  end

  def build! # rubocop:disable Metrics/MethodLength
    index = nil
    retired = nil
    ChatRing::KnowledgeBase.transaction do
      @knowledge_base.lock!
      materials = @knowledge_base.materials.retrievable.order(:id).lock.to_a
      if materials.empty?
        retired = @knowledge_base.active_knowledge_index
        @knowledge_base.update!(active_knowledge_index: nil)
        retired.update!(status: 'retired') if retired&.status == 'active'
        next
      end

      manifest = self.class.catalog_manifest(@knowledge_base)
      manifest_digest = Digest::SHA256.hexdigest(manifest.to_json)
      if @knowledge_base.active_knowledge_index&.manifest_digest == manifest_digest
        mark_materials_available!(@knowledge_base.active_knowledge_index, materials)
        next
      end
      next if @knowledge_base.knowledge_indexes.where(status: %w[building ready], manifest_digest: manifest_digest).exists?

      validate_corpus_size!(materials)
      index = @knowledge_base.knowledge_indexes.create!(
        workspace: @knowledge_base.workspace,
        status: 'building',
        provider: 'docs_gpt',
        provider_release: ENV.fetch('DOCSGPT_RELEASE', '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'),
        config_snapshot: ChatRing::Knowledge::SyncService.configuration_snapshot.merge(
          'build_mode' => 'material_catalog_index'
        ),
        mapped_manifest: manifest,
        manifest_digest: manifest_digest,
        crawl_errors: []
      )
      materials.each { |material| copy_material!(index, material) }
    end
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(knowledge_base: @knowledge_base) if retired
    index
  end

  private

  def mark_materials_available!(index, materials)
    active_material_ids = index.documents.where(knowledge_material_id: materials.map(&:id)).pluck(:knowledge_material_id)
    materials.each { |material| material.update!(status: 'available') if active_material_ids.include?(material.id) }
  end

  def copy_material!(index, material)
    verify_material!(material)
    structure = ChatRing::Knowledge::MarkdownStructure.new(
      markdown: material.markdown,
      source_url: material.public_url
    ).call
    index.documents.create!(
      knowledge_material: material,
      source_kind: material.source_kind,
      source_reference: material.source_reference,
      source_url: material.public_url,
      public_url: material.public_url,
      file_source: material.file_source,
      title: material.title,
      markdown: material.markdown,
      content_hash: material.content_hash,
      provider_file_name: provider_file_name(material),
      metadata: material.metadata.merge(
        structure,
        'authority_class' => material.authority_class,
        'material_key' => material.material_key
      ),
      provider_status: 'pending'
    )
  end

  def verify_material!(material)
    return if Digest::SHA256.hexdigest(material.markdown) == material.content_hash

    raise Error, "Knowledge material #{material.id} does not match its content hash"
  end

  def provider_file_name(material)
    "#{material.source_kind}-#{material.material_key}-#{material.content_hash.first(12)}.md"
  end

  def validate_corpus_size!(materials)
    total_bytes = materials.sum { |material| material.markdown.bytesize }
    return if total_bytes <= ChatRing::Knowledge::SourcePolicy::MAX_CORPUS_BYTES

    raise Error, "Knowledge corpus exceeds #{ChatRing::Knowledge::SourcePolicy::MAX_CORPUS_BYTES} bytes"
  end
end
