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
      history_message_ids: [13],
      strategy: 'dual_query_minimum_antecedent'
    )
    contextual_query = <<~QUERY.chomp
      ChatRing AI
      Tell me about Playbooks.
      How does it work?
    QUERY
    expect(result.retrieval_queries).to contain_exactly("ChatRing AI\nHow does it work?", contextual_query)
    expect(result.contextual_query).not_to include('Playbooks guide a multi-step sales flow.')
  end

  it 'keeps a standalone topic switch free from unrelated history' do
    result = described_class.new(
      raw_query: 'What integrations are available?',
      identity_anchor: 'ChatRing AI',
      history: [history_item(11, 'customer', 'What pricing plans are available?')]
    ).call

    expect(result).to have_attributes(
      retrieval_query: "ChatRing AI\nWhat integrations are available?",
      contextualized: false,
      history_message_ids: []
    )
    expect(result.retrieval_queries).to eq(["ChatRing AI\nWhat integrations are available?"])
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

  it 'does not treat generic other or same wording as a reference' do
    %w[other same].each do |word|
      result = described_class.new(
        raw_query: "What #{word} integrations are available?",
        identity_anchor: 'ChatRing AI',
        history: [history_item(11, 'customer', 'What pricing plans are available?')]
      ).call

      expect(result).to have_attributes(contextualized: false, history_message_ids: [])
      expect(result.retrieval_query).not_to include('pricing')
    end
  end

  it 'uses only the prior customer turn when it already contains the referenced alternatives' do
    result = described_class.new(
      raw_query: 'What did the other one include?',
      identity_anchor: 'ChatRing AI',
      history: [
        history_item(11, 'customer', 'Compare the Internet and TV plans.'),
        history_item(12, 'managed_ai', 'Internet includes a router; TV includes a streaming box.')
      ]
    ).call

    expect(result.history_message_ids).to eq([11])
    expect(result.contextual_query).to eq("Compare the Internet and TV plans.\nWhat did the other one include?")
    expect(result.contextual_query).not_to include('Internet includes a router')
  end

  it 'adds an allowed reference response when the prior customer turn does not contain the referenced alternatives' do
    result = described_class.new(
      raw_query: 'Which one includes Voice?',
      identity_anchor: 'ChatRing AI',
      history: [
        history_item(11, 'customer', 'What would you recommend?'),
        history_item(12, 'managed_ai', 'For your case I would compare Basic and Pro.')
      ]
    ).call

    expect(result.history_message_ids).to eq([11, 12])
    expect(result.contextual_query).to eq(
      "What would you recommend?\nFor your case I would compare Basic and Pro.\nWhich one includes Voice?"
    )
  end

  it 'does not build contextual retrieval from an untrusted external-bot response' do
    result = described_class.new(
      raw_query: 'Which one includes Voice?',
      identity_anchor: 'ChatRing AI',
      history: [
        history_item(11, 'customer', 'What would you recommend?'),
        history_item(12, 'external_bot_or_system', 'Basic and Pro are the choices.')
      ]
    ).call

    expect(result).to have_attributes(contextualized: false, history_message_ids: [])
    expect(result.retrieval_queries).to eq(["ChatRing AI\nWhich one includes Voice?"])
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

    expect(result.retrieval_queries).to all(satisfy { |query| query.length <= ChatRing::Knowledge::DocsGptProvider::MAX_QUERY_LENGTH })
    expect(result.retrieval_query).to start_with("ChatRing AI\nDoes that support voice?")
    expect(result.contextual_query).to include('Tell me about integrations.')
    expect(result.contextual_query).not_to include('unrelated support queue', 'We connect to approved business systems.')
  end

  it 'records only native message ids and query digests in the retrieval audit' do
    result = described_class.new(
      raw_query: 'Which one supports Salesforce?',
      identity_anchor: 'ChatRing AI',
      history: [
        history_item(11, 'customer', 'What would you recommend?'),
        history_item(12, 'human_agent', 'Salesforce is definitely supported.')
      ]
    ).call

    expect(result.audit_metadata).to include(
      'history_message_ids' => [11, 12],
      'query_count' => 2,
      'query_digests' => result.retrieval_queries.map { |query| Digest::SHA256.hexdigest(query) }
    )
    expect(result.audit_metadata.to_json).not_to include('Salesforce is definitely supported')
  end

  def history_item(message_id, speaker, content)
    { 'message_id' => message_id, 'speaker' => speaker, 'content' => content }
  end
end
