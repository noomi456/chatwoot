require 'rails_helper'

RSpec.describe ChatRing::Knowledge::MarkdownStructure do
  it 'preserves heading hierarchy and returns only safe source-derived CTA links' do
    markdown = <<~MARKDOWN
      # Pricing
      Compare the available plans.
      ## Plus
      #### Trial details
      [Start 14-day Trial](/signup)
      [Read the documentation](/docs)
      ![Book a Demo illustration](https://images.example.com/demo.png)
      #### Guided demo
      [Open in new tab](https://calendar.google.com/calendar/appointments/schedules/example)
      [Book a Demo](javascript:alert(1))
      [Talk to Sales](https://sales.example.net/contact)
      [Start 14-day Trial](/signup)
    MARKDOWN

    result = described_class.new(markdown: markdown, source_url: 'https://example.com/pricing').call

    expect(result.fetch('headings')).to eq(
      [
        { 'level' => 1, 'text' => 'Pricing', 'path' => 'Pricing' },
        { 'level' => 2, 'text' => 'Plus', 'path' => 'Pricing > Plus' },
        { 'level' => 4, 'text' => 'Trial details', 'path' => 'Pricing > Plus > Trial details' },
        { 'level' => 4, 'text' => 'Guided demo', 'path' => 'Pricing > Plus > Guided demo' }
      ]
    )
    expect(result.fetch('cta_candidates')).to contain_exactly(
      {
        'label' => 'Start 14-day Trial',
        'url' => 'https://example.com/signup',
        'heading_path' => 'Pricing > Plus > Trial details',
        'external' => false
      },
      {
        'label' => 'Open in new tab',
        'url' => 'https://calendar.google.com/calendar/appointments/schedules/example',
        'heading_path' => 'Pricing > Plus > Guided demo',
        'external' => true
      },
      {
        'label' => 'Talk to Sales',
        'url' => 'https://sales.example.net/contact',
        'heading_path' => 'Pricing > Plus > Guided demo',
        'external' => true
      },
      {
        'label' => 'Start 14-day Trial',
        'url' => 'https://example.com/signup',
        'heading_path' => 'Pricing > Plus > Guided demo',
        'external' => false
      }
    )
  end

  it 'rejects a non-HTTP source URL' do
    expect do
      described_class.new(markdown: '# Unsafe', source_url: 'file:///tmp/unsafe').call
    end.to raise_error(described_class::Error, /http or https/)
  end
end
