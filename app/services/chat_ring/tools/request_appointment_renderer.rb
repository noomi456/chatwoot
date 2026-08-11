class ChatRing::Tools::RequestAppointmentRenderer
  Result = Data.define(:content, :payload)

  def self.call(policy_version)
    configuration = policy_version.configuration_for('request_appointment')
    approved_url = configuration.fetch('url')
    label = configuration.fetch('link_label').to_s.strip
    escaped_label = label.gsub(/([\\`*_{}\[\]()#+\-.!|>])/) { |character| "\\#{character}" }
    Result.new(
      content: "#{escaped_label}\n#{approved_url}",
      payload: {
        'presentation_mode' => 'approved_link',
        'approved_url' => approved_url
      }.freeze
    )
  end
end
