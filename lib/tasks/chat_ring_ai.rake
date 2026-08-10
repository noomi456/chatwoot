namespace :chatring do
  namespace :ai do
    desc 'Resume one durable ready-to-commit ChatRing AI outcome by turn ID'
    task :resume_outcome, [:turn_id] => :environment do |_task, args|
      turn_id = Integer(args.fetch(:turn_id))
      result = ChatRing::OutboundCommitDispatcher.call(turn_id)
      puts({ ai_turn_id: turn_id, result: result }.to_json)
    end
  end
end
