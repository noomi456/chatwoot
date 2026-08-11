require 'rails_helper'

RSpec.describe ChatRing::HumanRouting::NativeAvailability do
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_widget, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  it 'requires both native business hours and an online Inbox member' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')

    expect(described_class.check(conversation)).to have_attributes(
      available: true,
      within_business_hours: true,
      eligible_agent_ids: [agent.id],
      assignee_id: agent.id,
      reason: nil
    )
  end

  it 'fails closed outside native business hours even when an agent is online' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')
    inbox.update!(working_hours_enabled: true)
    inbox.working_hours.today.update!(closed_all_day: true, open_all_day: false)

    expect(described_class.check(conversation)).to have_attributes(
      available: false,
      within_business_hours: false,
      eligible_agent_ids: [],
      reason: 'outside_business_hours'
    )
  end

  it 'requires an online agent to belong to the current native Conversation team' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    conversation.update!(team: create(:team, account: account))
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')

    expect(described_class.check(conversation)).to have_attributes(
      available: false,
      within_business_hours: true,
      eligible_agent_ids: [],
      reason: 'no_eligible_agent_online'
    )
  end

  it 'does not claim assignment eligibility when the native team disables auto assignment' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    team = create(:team, account: account, allow_auto_assign: false)
    create(:team_member, team: team, user: agent)
    conversation.update!(team: team)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')

    expect(described_class.check(conversation)).to have_attributes(
      available: false,
      within_business_hours: true,
      eligible_agent_ids: [],
      assignee_id: nil,
      reason: 'no_eligible_agent_assignable'
    )
  end

  it 'respects native assignment-v2 rate limits when selecting an available human' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    account.enable_features('assignment_v2')
    account.save!
    assignment_policy = create(:assignment_policy, account: account, enabled: true)
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: assignment_policy)
    inbox.reload
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')
    rate_limiter = instance_double(AutoAssignment::RateLimiter, within_limit?: false)
    allow(AutoAssignment::RateLimiter).to receive(:new).and_return(rate_limiter)

    expect(described_class.check(conversation)).to have_attributes(
      available: false,
      within_business_hours: true,
      eligible_agent_ids: [],
      assignee_id: nil,
      reason: 'no_eligible_agent_assignable'
    )
  end
end
