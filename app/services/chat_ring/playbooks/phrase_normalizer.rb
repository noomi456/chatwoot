class ChatRing::Playbooks::PhraseNormalizer
  MAX_LENGTH = 160

  def self.call(value)
    value.to_s.unicode_normalize(:nfkc)
         .downcase
         .gsub(/[[:space:]]+/, ' ')
         .strip
         .sub(/\A[[:punct:]]+/, '')
         .sub(/[[:punct:]]+\z/, '')
         .strip
  end
end
