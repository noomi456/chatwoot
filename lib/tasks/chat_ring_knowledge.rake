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
          accepted_manifest_count: version.mapped_manifest.count { |entry| entry['included'] },
          excluded_manifest_count: version.mapped_manifest.count { |entry| !entry['included'] },
          document_count: version.documents.count,
          ready_document_count: version.documents.where(provider_status: 'ready').count,
          provider_source_ids: version.documents.distinct.pluck(:provider_source_id).compact,
          evaluation_status: version.evaluation_status,
          evaluated_at: version.evaluated_at,
          evaluation_case_count: version.evaluation_report['case_count'],
          evaluation_passed_count: version.evaluation_report['passed_count'],
          failure_code: version.failure_code,
          failure_message: version.failure_message,
          abandoned_at: version.abandoned_at,
          abandon_reason: version.abandon_reason,
          provider_cleanup: version.provider_cleanup&.attributes&.slice(
            'id', 'status', 'attempts', 'manual_retry_count', 'eligible_at', 'next_attempt_at',
            'last_enqueued_at', 'lease_expires_at', 'cleaned_at', 'last_error'
          )
        }.to_json
      )
    end

    desc 'Evaluate a ready knowledge version using a JSON release-suite file'
    task :evaluate, [:knowledge_version_id, :suite_path] => :environment do |_task, args|
      suite_path = Pathname.new(args.fetch(:suite_path)).realpath
      cases = JSON.parse(File.read(suite_path))
      report = ChatRing::Knowledge::EvaluationService.evaluate!(
        ChatRing::KnowledgeVersion.find(args.fetch(:knowledge_version_id)),
        cases: cases
      )
      puts report.slice('suite_digest', 'case_count', 'passed_count').to_json
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

    desc 'Abandon an unpublished ready knowledge version and retain its provider index for the cleanup window'
    task :abandon, [:knowledge_version_id, :reason] => :environment do |_task, args|
      version = ChatRing::Knowledge::AbandonmentService.abandon!(
        ChatRing::KnowledgeVersion.find(args.fetch(:knowledge_version_id)),
        reason: args.fetch(:reason)
      )
      puts({ knowledge_version_id: version.id, status: version.status, abandoned_at: version.abandoned_at }.to_json)
    end

    desc 'Reconcile missing, overdue and expired-lease provider cleanup work now'
    task cleanup_reconcile: :environment do
      abandoned = ChatRing::Knowledge::AbandonmentService.abandon_overdue_evaluation_failures!
      ChatRing::Knowledge::ProviderCleanupReconciler.call
      puts(
        {
          abandoned_version_ids: abandoned.map(&:id),
          pending: ChatRing::KnowledgeProviderCleanup.where(status: 'pending').count,
          retrying: ChatRing::KnowledgeProviderCleanup.where(status: 'retrying').count,
          failed: ChatRing::KnowledgeProviderCleanup.where(status: 'failed').count
        }.to_json
      )
    end

    desc 'Report knowledge lifecycle repair candidates without changing state'
    task cleanup_report: :environment do
      puts ChatRing::Knowledge::ProviderCleanupReconciler.report.to_json
    end

    desc 'Explicitly retry one exhausted provider cleanup'
    task :cleanup_retry, [:cleanup_id] => :environment do |_task, args|
      cleanup = ChatRing::Knowledge::ProviderCleanupScheduler.retry_failed!(
        ChatRing::KnowledgeProviderCleanup.find(args.fetch(:cleanup_id))
      )
      puts({ cleanup_id: cleanup.id, status: cleanup.status, manual_retry_count: cleanup.manual_retry_count }.to_json)
    end

    desc 'Run narrow DocsGPT expired-idempotency housekeeping now'
    task provider_maintenance: :environment do
      result = ChatRing::Knowledge::DocsGptClient.new(
        base_url: ENV.fetch('DOCSGPT_BASE_URL'),
        jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
        internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
        service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
      ).cleanup_expired_idempotency
      puts result.to_json
    end
  end
end
# rubocop:enable Metrics/BlockLength
