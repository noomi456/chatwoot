class ChatRing::Knowledge::FileSourceReconciler
  STALE_PARSE_AGE = 1.hour
  STALE_UPLOAD_AGE = 10.minutes

  def self.call(now: Time.current)
    reconcile_stale_uploads(now)
    reconcile_stale_parses(now)
  end

  def self.reconcile_stale_uploads(now)
    ChatRing::KnowledgeFileSource.where(status: 'uploaded')
                                 .where('created_at < ?', now - STALE_UPLOAD_AGE)
                                 .find_each do |source|
      if source.file.attached?
        ChatRing::Knowledge::FileParseJob.perform_later(source.id)
      else
        source.update!(
          status: 'failed',
          failure_code: 'attachment_missing',
          failure_message: 'Uploaded file was not stored; upload it again'
        )
      end
    end
  end
  private_class_method :reconcile_stale_uploads

  def self.reconcile_stale_parses(now)
    stale = ChatRing::KnowledgeFileSource.where(status: 'parsing')
                                         .where('parse_started_at < ?', now - STALE_PARSE_AGE)
    stale.update_all( # rubocop:disable Rails/SkipsModelValidations
      status: 'parse_indeterminate',
      failure_code: 'stale_parse_reconciled',
      failure_message: 'Parser completion was not recorded; administrator retry is required',
      updated_at: now
    )
  end
  private_class_method :reconcile_stale_parses
end
