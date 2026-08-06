require 'rails_helper'

RSpec.describe ChatRing::Knowledge::SourcePolicy do
  subject(:policy) { described_class.new(root_url: 'https://example.com/') }

  it 'rejects mapped URLs outside the configured origin' do
    expect { policy.prepare_manifest([{ url: 'https://attacker.example/prompt' }]) }.to raise_error(
      described_class::OriginError,
      /outside the configured origin/
    )
  end

  it 'excludes non-knowledge routes and classifies source authority' do
    manifest = policy.prepare_manifest(
      [
        { url: 'https://example.com/login' },
        { url: 'https://example.com/docs/start' },
        { url: 'https://example.com/privacy' },
        { url: 'https://example.com/sitemap.xml' },
        { url: 'https://example.com/legal/policies/privacy-policy' },
        { url: 'https://example.com/company/privacy-statement', title: 'Privacy Policy | Example' },
        { url: 'https://example.com/blog/update' }
      ]
    )

    expect(manifest.find { |entry| entry['url'].end_with?('/login') }).to include(
      'included' => false,
      'exclusion_reason' => 'non_knowledge_route'
    )
    expect(manifest.find { |entry| entry['url'].end_with?('/docs/start') }['authority_class']).to eq('product_documentation')
    expect(manifest.find { |entry| entry['url'].end_with?('/privacy') }).to include(
      'included' => false,
      'exclusion_reason' => 'non_knowledge_route'
    )
    expect(manifest.find { |entry| entry['url'].end_with?('/sitemap.xml') }['included']).to be(false)
    expect(manifest.find { |entry| entry['url'].end_with?('/legal/policies/privacy-policy') }['included']).to be(false)
    expect(manifest.find { |entry| entry['url'].end_with?('/company/privacy-statement') }['included']).to be(false)
    expect(manifest.find { |entry| entry['url'].end_with?('/blog/update') }['included']).to be(false)
  end

  it 'excludes redundant help routes before scraping and cleans boilerplate from accepted pages' do
    manifest = policy.prepare_manifest(
      [
        { url: 'https://example.com/docs/start' },
        { url: 'https://example.com/help/start' }
      ]
    )
    content = [
      '# Start',
      'Useful product documentation. ' * 5,
      'We use cookies to run the site, improve performance, and remember your choices. You can change settings any time.'
    ].join("\n")
    expect(manifest.find { |entry| entry['url'].end_with?('/help/start') }).to include(
      'included' => false,
      'exclusion_reason' => 'redundant_help_route'
    )
    pages = manifest.select { |entry| entry['included'] }.map do |entry|
      {
        markdown: content,
        metadata: { sourceURL: entry['url'], title: 'Start', statusCode: 200, language: 'en', contentType: 'text/html' }
      }.deep_stringify_keys
    end

    result = policy.normalize_pages(records: pages, manifest: manifest)
    expect(result.one?).to be(true)
    expect(result.first[:source_url]).to eq('https://example.com/docs/start')
    expect(result.first[:markdown]).not_to include('We use cookies')
  end

  it 'rejects soft-404 and non-success pages' do
    manifest = policy.prepare_manifest([{ url: 'https://example.com/missing' }])
    record = {
      markdown: 'Page not found. This page does not exist on this website.',
      metadata: { sourceURL: 'https://example.com/missing', title: '404 Not Found', statusCode: 404 }
    }.deep_stringify_keys

    expect { policy.normalize_pages(records: [record], manifest: manifest) }.to raise_error(
      described_class::PageQualityError
    )
  end
end
