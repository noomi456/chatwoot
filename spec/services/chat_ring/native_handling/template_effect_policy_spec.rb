require 'rails_helper'

RSpec.describe ChatRing::NativeHandling::TemplateEffectPolicy do
  describe '.terminal_reason' do
    it 'keeps pinned email collection authoritative' do
      expect(described_class.terminal_reason('email_collection_required' => true)).to eq('native_email_collection')
    end

    it 'keeps pinned out-of-office handling authoritative' do
      expect(described_class.terminal_reason('inbox_out_of_office' => true)).to eq('native_out_of_office')
    end

    it 'preserves native out-of-office precedence when email collection is also required' do
      expect(
        described_class.terminal_reason(
          'email_collection_required' => true,
          'inbox_out_of_office' => true
        )
      ).to eq('native_out_of_office')
    end

    it 'uses the actual native template delta even when a later boolean is false' do
      expect(
        described_class.terminal_reason(
          'email_input_message_ids' => [456],
          'email_collection_required' => false
        )
      ).to eq('native_email_collection')
    end

    it 'fails closed when exact native template provenance could not be observed' do
      expect(
        described_class.terminal_reason('template_observation_error' => 'ActiveRecord::ConnectionNotEstablished')
      ).to eq('native_template_observation_failed')
    end

    it 'allows a nonterminal template snapshot' do
      expect(
        described_class.terminal_reason(
          'email_collection_required' => false,
          'inbox_out_of_office' => false,
          'greeting_message_ids' => [123]
        )
      ).to be_nil
    end
  end
end
