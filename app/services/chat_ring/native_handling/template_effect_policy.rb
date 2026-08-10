class ChatRing::NativeHandling::TemplateEffectPolicy
  class << self
    def terminal_reason(snapshot)
      return unless snapshot.is_a?(Hash)
      return 'native_template_observation_failed' if snapshot['template_observation_error'].present?
      return 'native_out_of_office' if effect_present?(snapshot, 'out_of_office_message_ids', 'inbox_out_of_office')
      return 'native_email_collection' if effect_present?(snapshot, 'email_input_message_ids', 'email_collection_required')

      nil
    end

    private

    def effect_present?(snapshot, ids_key, boolean_key)
      Array(snapshot[ids_key]).any? || snapshot[boolean_key] == true
    end
  end
end
