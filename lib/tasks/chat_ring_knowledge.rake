# rubocop:disable Metrics/BlockLength
namespace :chatring do
  namespace :knowledge do
    desc 'Start a Firecrawl map/exact batch scrape and DocsGPT knowledge build'
    task :start, [:account_id, :inbox_id, :root_url] => :environment do |_task, args|
      account = Account.find(args.fetch(:account_id))
      inbox = Inbox.find(args.fetch(:inbox_id))
      version = ChatRing::Knowledge::SyncService.start!(account: account, inbox: inbox, root_url: args.fetch(:root_url))
      puts({ knowledge_version_id: version.id, status: version.status }.to_json)
    end

    desc 'Show a knowledge version without exposing provider secrets'
    task :status, [:knowledge_version_id] => :environment do |_task, args|
      version = ChatRing::KnowledgeVersion.find(args.fetch(:knowledge_version_id))
      puts(
        {
          id: version.id,
          account_id: version.account_id,
          inbox_id: version.inbox_id,
          status: version.status,
          root_url: version.root_url,
          firecrawl_crawl_id: version.firecrawl_crawl_id,
          manifest_count: version.mapped_manifest.length,
          document_count: version.documents.count,
          ready_document_count: version.documents.where(provider_status: 'ready').count,
          provider_agent_id: version.provider_agent_id,
          failure_code: version.failure_code,
          failure_message: version.failure_message
        }.to_json
      )
    end

    desc 'Publish a ready knowledge version for its inbox'
    task :publish, [:knowledge_version_id] => :environment do |_task, args|
      publication = ChatRing::Knowledge::PublicationService.publish!(
        ChatRing::KnowledgeVersion.find(args.fetch(:knowledge_version_id))
      )
      puts({ inbox_id: publication.inbox_id, knowledge_version_id: publication.knowledge_version_id }.to_json)
    end

    desc 'Roll back an inbox to its previous published knowledge version'
    task :rollback, [:account_id, :inbox_id] => :environment do |_task, args|
      publication = ChatRing::Knowledge::PublicationService.rollback!(
        account: Account.find(args.fetch(:account_id)),
        inbox: Inbox.find(args.fetch(:inbox_id))
      )
      puts({ inbox_id: publication.inbox_id, knowledge_version_id: publication.knowledge_version_id }.to_json)
    end

    desc 'Retrieve published evidence for an inbox'
    task :retrieve, [:inbox_id, :query] => :environment do |_task, args|
      evidence = ChatRing::Knowledge::Retriever.retrieve(
        inbox: Inbox.find(args.fetch(:inbox_id)),
        query: args.fetch(:query)
      )
      puts evidence.to_h.merge(items: evidence.items.map(&:to_h)).to_json
    end
  end
end
# rubocop:enable Metrics/BlockLength
