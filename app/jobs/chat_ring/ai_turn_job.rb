class ChatRing::AiTurnJob < ApplicationJob
  queue_as :high

  retry_on ChatRing::Brain::Runner::RetryableError,
           wait: :polynomially_longer,
           attempts: 3 do |job, error|
    ChatRing::Brain::FailureFinalizer.call(job.arguments.first, error.code)
  end

  def perform(turn_id)
    turn = ChatRing::AiTurn.find_by(id: turn_id)
    ChatRing::Brain::Runner.new(turn).call if turn
  end
end
