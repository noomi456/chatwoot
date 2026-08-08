namespace :chatring do
  namespace :knowledge do
    desc 'Show the account Training Materials and hidden provider-index state'
    task :status, [:account_id] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
      active_index = knowledge_base.active_knowledge_index
      puts(
        {
          account_id: account.id,
          workspace_id: knowledge_base.workspace_id,
          knowledge_base_id: knowledge_base.id,
          active_knowledge_index_id: active_index&.id,
          active_provider_source_ids: active_index&.documents&.distinct&.pluck(:provider_source_id)&.compact || [],
          materials: knowledge_base.materials.active.order(:id).map do |material|
            {
              id: material.id,
              material_key: material.material_key,
              type: material.source_kind,
              name: material.title,
              source_reference: material.source_reference,
              status: material.status,
              extracted_at: material.extracted_at,
              available_to_ai: active_index&.documents&.exists?(knowledge_material_id: material.id) || false
            }
          end
        }.to_json
      )
    end

    desc 'Retrieve evidence through the account Knowledge Base used by an Inbox'
    task :retrieve, [:inbox_id, :query] => :environment do |_task, args|
      evidence = ChatRing::Knowledge::Retriever.retrieve(
        inbox: Inbox.find(args.fetch(:inbox_id)),
        query: args.fetch(:query)
      )
      puts evidence.to_h.merge(items: evidence.items.map(&:to_h)).to_json
    end

    desc 'Retry one failed obsolete-provider-index deletion'
    task :cleanup_retry, [:cleanup_id] => :environment do |_task, args|
      cleanup = ChatRing::Knowledge::ProviderCleanupScheduler.retry_failed!(
        ChatRing::KnowledgeProviderCleanup.find(args.fetch(:cleanup_id))
      )
      puts({ cleanup_id: cleanup.id, status: cleanup.status }.to_json)
    end
  end
end
