class ChatRing::Tools::VisitorPresentation
  KEYS = %w[presentation_mode provider approved_url link_label].freeze

  def self.call(execution)
    supported = execution&.tool_key == 'request_appointment' && execution.tool_version == 1
    raise ArgumentError, 'Unsupported ChatRing Tool presentation' unless supported

    execution.result_payload.slice(*KEYS)
  end
end
