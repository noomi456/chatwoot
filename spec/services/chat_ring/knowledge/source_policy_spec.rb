require 'rails_helper'

RSpec.describe ChatRing::Knowledge::SourcePolicy do
  subject(:policy) { described_class.new(root_url: 'https://example.com/') }

  it 'excludes useless operational and policy routes before paid extraction' do
    manifest = policy.prepare_manifest(
      [
        { url: 'https://example.com/login' },
        { url: 'https://example.com/privacy-policy' },
        { url: 'https://example.com/cookies' },
        { url: 'https://example.com/terms-of-service' },
        { url: 'https://example.com/sitemap.xml' },
        { url: 'https://example.com/docs/start' },
        { url: 'https://example.com/help/getting-started' },
        { url: 'https://example.com/blog/product-news' },
        { url: 'https://example.com/features' }
      ]
    )

    expect(manifest.reject { |entry| entry['included'] }.pluck('url')).to contain_exactly(
      'https://example.com/cookies',
      'https://example.com/docs/start',
      'https://example.com/help/getting-started',
      'https://example.com/blog/product-news',
      'https://example.com/login',
      'https://example.com/privacy-policy',
      'https://example.com/sitemap.xml',
      'https://example.com/terms-of-service'
    )
    expect(manifest.find { |entry| entry['url'].end_with?('/features') }).to include('included' => true)
  end

  it 'keeps security text, named examples, and non-English pages as customer content' do
    manifest = policy.prepare_manifest([{ url: 'https://example.com/security-update' }])
    markdown = <<~MARKDOWN
      # Actualización de seguridad

      Sarah Connor at Acme Corp documents SOC 2, HIPAA, encryption, residency, and prompt injection protection.
      This is legitimate customer content and must remain intact.
    MARKDOWN
    record = {
      markdown: markdown,
      metadata: {
        sourceURL: 'https://example.com/security-update', title: 'Actualización',
        statusCode: 200, language: 'es'
      }
    }.deep_stringify_keys

    result = policy.normalize_pages(records: [record], manifest: manifest).first
    expect(result.fetch(:markdown)).to eq(markdown.strip)
    expect(result.fetch(:risk_flags)).to contain_exactly('possible_prompt_injection')
  end

  it 'retains successful requested pages and reports a failed page separately' do
    manifest = policy.prepare_manifest(
      [{ url: 'https://example.com/good' }, { url: 'https://example.com/missing' }]
    )
    records = [{
      markdown: '# Good\n\nUseful product information that is long enough to be accepted by the knowledge policy.',
      metadata: { sourceURL: 'https://example.com/good', title: 'Good', statusCode: 200 }
    }.deep_stringify_keys]

    pages, errors = policy.normalize_pages_with_errors(records: records, manifest: manifest)

    expect(pages.pluck(:source_reference)).to eq(['https://example.com/good'])
    expect(errors).to contain_exactly(
      'url' => 'https://example.com/missing',
      'error' => 'Firecrawl did not return this requested page'
    )
  end

  it 'rejects mapped URLs outside the submitted website origin' do
    expect { policy.prepare_manifest([{ url: 'https://attacker.example/prompt' }]) }
      .to raise_error(described_class::OriginError, /outside the configured origin/)
  end

  it 'keeps the requested material identity when Firecrawl reports a normal canonical redirect' do
    manifest = policy.prepare_manifest([{ url: 'http://example.com/features?id=123' }])
    records = [{
      markdown: '# Features\n\nUseful product information that is long enough for the knowledge base.',
      metadata: { sourceURL: 'https://www.example.com/features?id=123', title: 'Features', statusCode: 200 }
    }.deep_stringify_keys]

    page = policy.normalize_pages(records: records, manifest: manifest).first

    expect(page).to include(
      source_reference: 'http://example.com/features?id=123',
      public_url: 'https://www.example.com/features?id=123'
    )
  end
end
