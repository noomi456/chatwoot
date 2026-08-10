# frozen_string_literal: true

# This isolated fault-injection proxy deliberately keeps its request bridge in one
# place so the proof does not introduce production middleware.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength

require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'webrick'

class ChatRingProofLlmProxy
  COPY_RESPONSE_HEADERS = %w[content-type openai-processing-ms x-request-id].freeze
  HOP_BY_HOP_HEADERS = %w[connection content-length host transfer-encoding].freeze

  def initialize
    @upstream = URI(ENV.fetch('PROOF_LLM_UPSTREAM', 'https://api.openai.com'))
    @state_dir = ENV.fetch('PROOF_STATE_DIR', '/proof-state')
    FileUtils.mkdir_p(@state_dir)
  end

  def call(request, response)
    return health(response) if request.path == '/health'

    body = request.body.to_s
    return unavailable(response) if body.include?('[[PROOF_FAIL_503]]')

    wait_at_barrier if body.include?('[[PROOF_HOLD]]')
    return local_completion(response, body) if body.include?('[[PROOF_LOCAL_REPLY]]')

    forward(request, response, body)
  rescue StandardError
    response.status = 502
    response['content-type'] = 'application/json'
    response.body = '{"error":{"message":"proof proxy upstream failure"}}'
  end

  private

  attr_reader :upstream, :state_dir

  def health(response)
    response.status = 200
    response['content-type'] = 'text/plain'
    response.body = 'ok'
  end

  def unavailable(response)
    response.status = 503
    response['content-type'] = 'application/json'
    response.body = '{"error":{"message":"proof provider unavailable"}}'
  end

  def local_completion(response, request_body)
    evidence_id = first_evidence_id(request_body)
    decision = {
      decision_type: evidence_id ? 'reply' : 'handoff',
      response_text: evidence_id ? 'The current plans are listed in the cited pricing source.' : '',
      reason_code: evidence_id ? 'answered' : 'insufficient_evidence',
      evidence_ids: evidence_id ? [evidence_id] : []
    }
    response.status = 200
    response['content-type'] = 'application/json'
    response.body = JSON.generate(
      id: "proof-#{Process.clock_gettime(Process::CLOCK_MONOTONIC).to_i}",
      object: 'chat.completion',
      created: Time.now.to_i,
      model: 'gpt-5.4',
      choices: [{ index: 0, message: { role: 'assistant', content: JSON.generate(decision) }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 }
    )
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

  def forward(request, response, body)
    uri = upstream.dup
    uri.path = request.path
    uri.query = request.query_string unless request.query_string.to_s.empty?
    upstream_request = Net::HTTP::Post.new(uri)
    request.header.each do |name, values|
      next if HOP_BY_HOP_HEADERS.include?(name.downcase)

      upstream_request[name] = Array(values).join(', ')
    end
    upstream_request.body = body
    upstream_response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: 10,
      read_timeout: 60,
      write_timeout: 10
    ) { |http| http.request(upstream_request) }

    response.status = upstream_response.code.to_i
    COPY_RESPONSE_HEADERS.each do |header|
      value = upstream_response[header]
      response[header] = value if value
    end
    response.body = upstream_response.body
  end
end

proxy = ChatRingProofLlmProxy.new
server = WEBrick::HTTPServer.new(
  Port: Integer(ENV.fetch('PORT', '8080')),
  BindAddress: '0.0.0.0',
  Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
  AccessLog: []
)
server.mount_proc('/') { |request, response| proxy.call(request, response) }
trap('TERM') { server.shutdown }
trap('INT') { server.shutdown }
server.start
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
