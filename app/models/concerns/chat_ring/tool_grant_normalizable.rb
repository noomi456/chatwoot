module ChatRing::ToolGrantNormalizable
  extend ActiveSupport::Concern

  included do
    before_validation :normalize_tool_grants
  end

  private

  def normalize_tool_grants
    self.tool_grants = ChatRing::Tools::GrantSet.new(tool_grants).entries.map(&:dup)
  rescue ChatRing::Tools::GrantSet::Invalid
    nil
  end
end
