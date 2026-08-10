class Api::V1::Accounts::ChatRing::AiTurnsController < Api::V1::Accounts::ChatRing::AssistantManagementBaseController
  def index
    authorize(ChatRing::AiTurn, :index?)
    turns = turn_scope.order(id: :desc).limit(100)
    render json: turns.map { |turn| serialize_turn(turn) }
  end

  def show
    turn = turn_scope.find(params[:id])
    authorize(turn)
    render json: serialize_turn(turn, include_details: true)
  end

  private

  def turn_scope
    scope = workspace.ai_turns.includes(:conversation, :attempts, :evidence, :outbound_commit)
    scope = scope.where(status: requested_status) if params[:status].present?
    scope = scope.where(assistant_id: params[:assistant_id]) if params[:assistant_id].present?
    scope
  end

  def requested_status
    ChatRing::AiTurn.statuses.fetch(params[:status])
  rescue KeyError
    raise ActionController::BadRequest, 'Unknown AI turn status'
  end
end
