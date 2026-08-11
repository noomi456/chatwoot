# frozen_string_literal: true

# This isolated fault-injection proxy deliberately keeps its request bridge in one
# place so the proof does not introduce production middleware.
require 'fileutils'
require 'json'
require 'net/http'
require 'puma'
require 'rack'
require 'uri'

class ChatRingProofLlmProxy
  COPY_RESPONSE_HEADERS = %w[content-type openai-processing-ms x-request-id].freeze
  HOP_BY_HOP_HEADERS = %w[connection content-length host transfer-encoding].freeze
  PROVIDER_UNAVAILABLE = '{"error":{"message":"proof provider unavailable"}}'
  UPSTREAM_FAILURE = '{"error":{"message":"proof proxy upstream failure"}}'

  def initialize
    @upstream = URI(ENV.fetch('PROOF_LLM_UPSTREAM', 'https://api.openai.com'))
    @state_dir = ENV.fetch('PROOF_STATE_DIR', '/proof-state')
    FileUtils.mkdir_p(@state_dir)
  end

  def call(environment)
    request = Rack::Request.new(environment)
    return response(200, 'text/plain', 'ok') if request.path == '/health'

    body = request.body.read
    return response(503, 'application/json', PROVIDER_UNAVAILABLE) if body.include?('[[PROOF_FAIL_503]]')

    wait_at_barrier if body.include?('[[PROOF_HOLD]]')
    return local_completion(body) if body.include?('[[PROOF_LOCAL_REPLY]]')

    forward(request, body)
  rescue StandardError
    response(502, 'application/json', UPSTREAM_FAILURE)
  end

  private

  attr_reader :upstream, :state_dir

  def response(status, content_type, body)
    [status, { 'content-type' => content_type, 'content-length' => body.bytesize.to_s }, [body]]
  end

  def local_completion(request_body)
    evidence_id = first_evidence_id(request_body)
    decision = {
      decision_type: evidence_id ? 'reply' : 'handoff',
      response_text: evidence_id ? 'The current plans are listed in the cited pricing source.' : '',
      reason_code: evidence_id ? 'answered' : 'insufficient_evidence',
      evidence_ids: evidence_id ? [evidence_id] : []
    }
    body = JSON.generate(
      id: "proof-#{Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i}",
      object: 'chat.completion',
      created: Time.now.to_i,
      model: 'gpt-5.4',
      choices: [{ index: 0, message: { role: 'assistant', content: JSON.generate(decision) }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 }
    )
    response(200, 'application/json', body)
  end

  def first_evidence_id(request_body)
    payload = JSON.parse(request_body)
    prompt = payload.fetch('messages').last.fetch('content')
    context = JSON.parse(prompt)
    context.fetch('evidence', []).first&.fetch('id', nil)
  rescue JSON::ParserError, KeyError, TypeError
    nil
  end

  def wait_at_barrier
    increment_counter
    entered = File.join(state_dir, 'provider_entered')
    release = File.join(state_dir, 'release_provider')
    FileUtils.touch(entered)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
    sleep 0.05 until File.exist?(release) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  end

  def increment_counter
    path = File.join(state_dir, 'provider_count')
    File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      count = file.read.to_i + 1
      file.rewind
      file.truncate(0)
      file.write(count.to_s)
      file.flush
    end
  end

  def forward(request, body)
    uri = upstream_uri(request)
    upstream_response = perform_upstream_request(uri, upstream_request(request, uri, body))
    proxy_response(upstream_response)
  end

  def upstream_uri(request)
    uri = upstream.dup
    uri.path = request.path
    uri.query = request.query_string unless request.query_string.to_s.empty?
    uri
  end

  def upstream_request(request, uri, body)
    result = Net::HTTP::Post.new(uri)
    request.env.each do |key, value|
      next unless key.start_with?('HTTP_')

      name = key.delete_prefix('HTTP_').downcase.tr('_', '-')
      next if HOP_BY_HOP_HEADERS.include?(name.downcase)

      result[name] = value
    end
    result['content-type'] = request.content_type if request.content_type
    result.body = body
    result
  end

  def perform_upstream_request(uri, request)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: 10,
      read_timeout: 60,
      write_timeout: 10
    ) { |http| http.request(request) }
  end

  def proxy_response(upstream_response)
    headers = {}
    COPY_RESPONSE_HEADERS.each do |header|
      value = upstream_response[header]
      headers[header] = value if value
    end
    response_body = upstream_response.body.to_s
    headers['content-length'] = response_body.bytesize.to_s
    [upstream_response.code.to_i, headers, [response_body]]
  end
end

proxy = ChatRingProofLlmProxy.new
server = Puma::Server.new(proxy)
server.add_tcp_listener('0.0.0.0', Integer(ENV.fetch('PORT', '8080')))
trap('TERM') { server.stop(true) }
trap('INT') { server.stop(true) }
server.run.join
