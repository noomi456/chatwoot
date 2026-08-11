require 'rails_helper'

RSpec.describe ChatRing::Knowledge::RetrievalQueryResolver do
  it 'uses the latest customer exchange to resolve a reference-dependent follow-up' do
    result = described_class.new(
      raw_query: 'How does it work?',
      identity_anchor: 'ChatRing AI',
      history: [
        history_item(11, 'customer', 'What pricing plans are available?'),
        history_item(12, 'managed_ai', 'We offer several pricing plans.'),
        history_item(13, 'customer', 'Tell me about Playbooks.'),
        history_item(14, 'managed_ai', 'Playbooks guide a multi-step sales flow.')
      ]
    ).call

    expect(result).to have_attributes(
      raw_query: 'How does it work?',
      contextualized: true,
      history_message_ids: [13, 14],
      strategy: 'bounded_native_history'
    )
    expect(result.standalone_query).to include(
      'Current question: How does it work?',
      'Customer: Tell me about Playbooks.',
      'Previous response: Playbooks guide a multi-step sales flow.'
    )
  end

  it 'keeps a standalone topic switch free from unrelated history' do
    result = described_class.new(
      raw_query: 'What integrations are available?',
      identity_anchor: 'ChatRing AI',
      history: [history_item(11, 'customer', 'What pricing plans are available?')]
    ).call

    expect(result).to have_attributes(
      standalone_query: 'What integrations are available?',
      retrieval_query: "ChatRing AI\nWhat integrations are available?",
      contextualized: false,
      history_message_ids: []
    )
  end

  it 'does not treat an explicit what-about topic as a dependent reference' do
    result = described_class.new(
      raw_query: 'What about integrations?',
      identity_anchor: 'ChatRing AI',
      history: [history_item(11, 'customer', 'What pricing plans are available?')]
    ).call

    expect(result.contextualized).to be(false)
    expect(result.retrieval_query).not_to include('pricing')
  end

  it 'excludes native templates and bounds the provider query' do
    result = described_class.new(
      raw_query: "Does that support voice? #{'x' * 3000}",
      identity_anchor: 'ChatRing AI',
      history: [
        history_item(11, 'native_template', 'Welcome to an unrelated support queue.'),
        history_item(12, 'customer', 'Tell me about integrations.'),
        history_item(13, 'managed_ai', 'We connect to approved business systems.')
      ]
    ).call

    expect(result.retrieval_query.length).to be <= ChatRing::Knowledge::DocsGptProvider::MAX_QUERY_LENGTH
    expect(result.retrieval_query).to include('Tell me about integrations.', 'We connect to approved business systems.')
    expect(result.retrieval_query).not_to include('unrelated support queue')
  end

  def history_item(message_id, speaker, content)
    { 'message_id' => message_id, 'speaker' => speaker, 'content' => content }
  end
end
