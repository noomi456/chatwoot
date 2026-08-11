class ChatRing::MicrositesController < ActionController::Base
  helper_method :safe_public_url?

  def show
    @artifact = ChatRing::MicrositeArtifact.available.find_by!(public_token: params[:token])
    @content = @artifact.content.deep_stringify_keys
    expires_in 5.minutes, public: true
  end

  private

  def safe_public_url?(value)
    ChatRing::Knowledge::MarkdownStructure.safe_public_http_url?(value.to_s)
  end
end
