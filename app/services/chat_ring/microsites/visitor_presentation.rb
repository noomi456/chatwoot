require 'uri'

class ChatRing::Microsites::VisitorPresentation
  def self.call(artifact)
    new(artifact).call
  end

  def initialize(artifact)
    @artifact = artifact
  end

  def call
    {
      'title' => artifact.content['title'].to_s.truncate(160, omission: ''),
      'url' => public_url,
      'section_types' => Array(artifact.content['sections']).pluck('type'),
      'expires_at' => artifact.expires_at.iso8601
    }
  end

  private

  attr_reader :artifact

  def public_url
    base = ENV.fetch('CHATRING_MICROSITE_SHARE_BASE_URL') do
      ENV.fetch('FRONTEND_URL', Rails.application.routes.default_url_options[:host])
    end
    uri = URI.parse(base.to_s)
    raise ArgumentError, 'Microsite share base URL is invalid' unless uri.is_a?(URI::HTTPS) && uri.host.present?

    "#{base.to_s.delete_suffix('/')}/s/#{artifact.public_token}"
  rescue URI::Error
    raise ArgumentError, 'Microsite share base URL is invalid'
  end
end
