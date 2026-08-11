require 'rails_helper'

describe '/widget', type: :request do
  let(:account) { create(:account) }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: web_widget.inbox) }
  let(:payload) { { source_id: contact_inbox.source_id, inbox_id: web_widget.inbox.id } }
  let(:token) { Widget::TokenService.new(payload: payload).generate_token }

  describe 'GET /widget' do
    it 'renders the page correctly when called with website_token' do
      get widget_url(website_token: web_widget.website_token)
      expect(response).to be_successful
      expect(response.body).not_to include(token)
    end

    it 'renders the page correctly when called with website_token and cw_conversation' do
      get widget_url(website_token: web_widget.website_token, cw_conversation: token)
      expect(response).to be_successful
      expect(response.body).to include(token)
    end

    it 'renders active Inbox-owned starters without adding a second visitor action path' do
      ChatRing::InboxConversationStarter.create!(
        workspace: ChatRing::Workspace.for_account!(account),
        inbox: web_widget.inbox,
        starters: [{ 'label' => 'See pricing', 'prompt' => 'What pricing plans do you offer?' }]
      )

      get widget_url(website_token: web_widget.website_token)

      expect(response).to be_successful
      expect(response.body).to include('conversationStarters')
      expect(response.body).to include('What pricing plans do you offer?')
    end

    it 'escapes configured starter text at the HTML script boundary' do
      ChatRing::InboxConversationStarter.create!(
        workspace: ChatRing::Workspace.for_account!(account),
        inbox: web_widget.inbox,
        starters: [{ 'label' => 'Unsafe', 'prompt' => '</script><script>alert(1)</script>' }]
      )

      get widget_url(website_token: web_widget.website_token)

      expect(response).to be_successful
      expect(response.body).not_to include('</script><script>alert(1)</script>')
      expect(response.body).to include('\\u003c/script\\u003e')
    end

    it 'returns 404 when called with out website_token' do
      get widget_url
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 401 if the account is suspended' do
      account.update!(status: :suspended)

      get widget_url(website_token: web_widget.website_token)
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include('Account is suspended')
    end

    it 'returns 404 if the webwidget is deleted' do
      web_widget.delete

      get widget_url(website_token: web_widget.website_token)
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('web widget does not exist')
    end
  end
end
