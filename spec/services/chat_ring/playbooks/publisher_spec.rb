require 'rails_helper'

RSpec.describe ChatRing::Playbooks::Publisher do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:playbook) do
    workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: actor,
      name: 'Pricing discovery',
      purpose: 'Qualify a visitor before the next sales action.',
      draft_definition: definition
    )
  end
  let(:definition) do
    {
      trigger_phrases: ['How much is internet?'],
      entry_step_id: 'ask_need',
      collected_fields: [
        { key: 'service_need', type: 'string', required: true, native_contact_attribute_key: nil }
      ],
      tool_allowlist: [],
      steps: [
        { id: 'ask_need', kind: 'ask_text', prompt: 'What service do you need?', field_key: 'service_need', next_step_id: 'complete' },
        { id: 'complete', kind: 'terminal', outcome: 'complete', message: 'Thank you. Your request is complete.' }
      ],
      safety_rules: {
        on_human_request: 'native_availability',
        on_side_question: 'answer_then_resume'
      }
    }
  end

  it 'publishes an immutable typed version owned by one native Inbox' do
    version = publish(playbook)

    expect(playbook.reload).to have_attributes(status: 'active', current_version: version)
    expect(version.definition['trigger_phrases']).to eq(['how much is internet'])
    expect(version.capability_snapshot).to include('chatwoot_inbox_id' => inbox.id, 'channel_type' => 'Channel::WebWidget')
    expect(version.validation_result).to include('valid' => true, 'errors' => [])
    expect(version.update(definition: {})).to be(false)
  end

  it 'rejects choice labels and values that could exceed the bounded native Message contract' do
    definition[:steps] = [
      {
        id: 'ask_need', kind: 'ask_choice', prompt: 'Choose one', field_key: 'service_need',
        choices: [
          { label: 'A' * 161, value: 'internet', next_step_id: 'complete' },
          { label: 'Television', value: 'v' * 161, next_step_id: 'complete' }
        ]
      },
      { id: 'complete', kind: 'terminal', outcome: 'complete', message: 'Thank you. Your request is complete.' }
    ]

    expect { publish(playbook) }.to raise_error(ChatRing::Playbooks::Publisher::InvalidDefinition) do |error|
      expect(error.result.errors.pluck(:code)).to include('choice_label_too_long', 'choice_value_too_long')
    end
  end

  it 'rejects a stale publisher without creating another version' do
    publish(playbook)

    expect { publish(playbook, lock_version: 0) }.to raise_error(described_class::InvalidRevision)
    expect(playbook.versions.count).to eq(1)
  end

  it 'rejects ambiguous phrases already published by the same Inbox' do
    publish(playbook)
    conflicting = workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: actor,
      name: 'Second pricing flow',
      purpose: 'A conflicting flow.',
      draft_definition: definition
    )

    expect { publish(conflicting) }
      .to raise_error(described_class::InvalidDefinition) do |error|
        expect(error.result.errors).to include(include(code: 'trigger_conflict'))
      end
  end

  it 'rejects an untyped or cyclic step graph' do
    playbook.draft_definition = definition.deep_merge(
      steps: [
        { id: 'ask_need', kind: 'ask_text', prompt: 'What service?', field_key: 'service_need', next_step_id: 'ask_need' }
      ]
    )
    playbook.save!

    expect { publish(playbook, lock_version: playbook.lock_version) }
      .to raise_error(described_class::InvalidDefinition) do |error|
      expect(error.result.errors).to include(include(code: 'step_cycle'))
    end
  end

  it 'requires published terminal copy and every completion path to collect required fields' do
    definition[:steps] = [
      {
        id: 'ask_need', kind: 'ask_choice', prompt: 'Choose one', field_key: 'service_need',
        choices: [
          { label: 'Answer', value: 'answer', next_step_id: 'complete' },
          { label: 'Skip', value: 'skip', next_step_id: 'complete' }
        ]
      },
      { id: 'complete', kind: 'terminal', outcome: 'complete' }
    ]

    expect { publish(playbook) }.to raise_error(described_class::InvalidDefinition) do |error|
      expect(error.result.errors.pluck(:code)).to include('missing_step_text')
    end

    definition[:entry_step_id] = 'complete'
    definition[:steps] = [
      { id: 'complete', kind: 'terminal', outcome: 'complete', message: 'Thank you.' }
    ]
    playbook.update!(draft_definition: definition)

    expect { publish(playbook, lock_version: playbook.lock_version) }.to raise_error(described_class::InvalidDefinition) do |error|
      expect(error.result.errors.pluck(:code)).to include('required_fields_incomplete')
    end
  end

  it 'rejects native Contact projection until the audited native mutation seam exists' do
    definition[:collected_fields].first[:native_contact_attribute_key] = 'service_need'

    expect { publish(playbook) }.to raise_error(described_class::InvalidDefinition) do |error|
      expect(error.result.errors.pluck(:code)).to include('native_contact_projection_unsupported')
    end
  end

  it 'rejects Tool and transition steps until their native-first execution paths are certified', :aggregate_failures do
    playbook.draft_definition = definition.deep_merge(
      tool_allowlist: [{ key: 'request_appointment', version: 1 }],
      steps: [
        {
          id: 'appointment', kind: 'tool', tool: { key: 'request_appointment', version: 1 },
          tool_allowlist: [{ key: 'request_appointment', version: 1 }]
        }
      ],
      entry_step_id: 'appointment',
      collected_fields: []
    )
    playbook.save!

    expect { publish(playbook, lock_version: playbook.lock_version) }
      .to raise_error(described_class::InvalidDefinition) do |error|
      expect(error.result.errors).to include(include(code: 'invalid_step_kind'))
    end
    playbook.draft_definition = definition.deep_merge(
      steps: [{ id: 'switch', kind: 'transition', target_playbook_version_id: 123, carry_fields: [] }],
      entry_step_id: 'switch',
      collected_fields: []
    )
    playbook.save!

    expect { publish(playbook, lock_version: playbook.lock_version) }
      .to raise_error(described_class::InvalidDefinition) do |error|
      expect(error.result.errors).to include(include(code: 'invalid_step_kind'))
    end
  end

  private

  def publish(item, lock_version: item.lock_version)
    described_class.new(
      playbook: item,
      actor: actor,
      expected_lock_version: lock_version
    ).call
  end
end
