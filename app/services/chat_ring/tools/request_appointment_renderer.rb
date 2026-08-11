class ChatRing::Tools::RequestAppointmentRenderer
  Result = Data.define(:content, :payload)
  PRESENTATION_COPY = {
    'outside_business_hours' => 'Our team is currently outside business hours. You can choose an appointment time here:',
    'no_eligible_agent_online' => 'Our team is currently unavailable. You can choose an appointment time here:',
    'no_eligible_agent_assignable' => 'We could not connect you to an available human right now. You can choose an appointment time here:',
    'agent_availability_unavailable' => 'We could not confirm a human is available right now. You can choose an appointment time here:'
  }.freeze
  AUTHORIZATION_CONTEXT = {
    'authorized_human_outside_hours' => 'outside_business_hours',
    'authorized_human_unavailable' => 'no_eligible_agent_online',
    'authorized_human_assignment_unavailable' => 'no_eligible_agent_assignable',
    'authorized_human_availability_unknown' => 'agent_availability_unavailable'
  }.freeze

  def self.call(policy_version, presentation_context: nil)
    configuration = policy_version.configuration_for('request_appointment')
    approved_url = configuration.fetch('url')
    label = configuration.fetch('link_label').to_s.strip
    escaped_label = label.gsub(/([\\`*_{}\[\]()#+\-.!|>])/) { |character| "\\#{character}" }
    link_content = "#{escaped_label}\n#{approved_url}"
    content = [PRESENTATION_COPY[presentation_context], link_content].compact.join("\n\n")
    Result.new(
      content: content,
      payload: {
        'presentation_mode' => 'approved_link',
        'approved_url' => approved_url
      }.freeze
    )
  end

  def self.presentation_context(authorization_result)
    AUTHORIZATION_CONTEXT[authorization_result.to_s]
  end
end
