require 'fluent/output'
require 'httpclient'
require 'json'

# http://dev.splunk.com/view/event-collector/SP-CAAAE6P

module Fluent
  class SplunkHECOutput < ObjectBufferedOutput
    Fluent::Plugin.register_output('splunk_hec', self)

    config_param :host, :string, default: 'localhost'
    config_param :port, :integer, default: 8088
    config_param :token, :string, required: true

    # for metadata
    config_param :default_host, :string, default: nil
    config_param :host_key, :string, default: nil
    config_param :default_source, :string, default: nil
    config_param :source_key, :string, default: nil
    config_param :default_index, :string, default: nil
    config_param :index_key, :string, default: nil
    config_param :sourcetype, :string, default: nil

    # for Indexer acknowledgement
    config_param :use_ack, :bool, default: false
    config_param :channel, :string, default: nil
    config_param :ack_interval, :integer, default: 1
    config_param :ack_retry_limit, :integer, default: 3

    ## TODO: more detailed option?
    ## For SSL
    config_param :ssl_verify_peer, :bool, default: false
    config_param :ca_file, :string, default: nil
    config_param :client_cert, :string, default: nil
    config_param :client_key, :string, default: nil
    config_param :client_key_pass, :string, default: nil

    # for raw events
    config_param :raw, :bool, default: false
    config_param :event_key, :string, default: nil

    # for raw=false and event_key
    config_param :use_fluentd_time, :bool, default: false

    # misc
    config_param :line_breaker, :string, default: "\n"

    def configure(conf)
      super
      raise ConfigError, "'channel' parameter is required when 'use_ack' is true" if @use_ack && !@channel
      raise ConfigError, "'ack_interval' parameter must be a non negative integer" if @use_ack && @ack_interval < 0
      raise ConfigError, "'event_key' parameter is required when 'raw' is true" if @raw && !@event_key
      raise ConfigError, "'channel' parameter is required when 'raw' is true" if @raw && !@channel

      # build hash for query string
      if @raw
        @query = {}
        @query['host'] = @default_host if @default_host
        @query['source'] = @default_source if @default_source
        @query['index'] = @default_index if @default_index
        @query['sourcetype'] = @sourcetype if @sourcetype
      end
    end

    def start
      setup_client
      super
    end

    def shutdown
      super
    end

    def write_objects(_tag, chunk)
      return if chunk.empty?

      payload = ''
      chunk.msgpack_each do |time, record|
        payload << (@raw ? format_event_raw(record) : format_event(time, record))
      end
      post_payload(payload) unless payload.empty?
    end

    private
    def setup_client
      header = {'Content-type' => 'application/json',
                'Authorization' => "Splunk #{@token}"}
      header['X-Splunk-Request-Channel'] = @channel if @channel
      base_url = @ssl_verify_peer ? URI::HTTPS.build(host: @host, port: @port) : URI::HTTP.build(host: @host, port: @port)
      @client = HTTPClient.new(default_header: header,
                               base_url: base_url)
      @client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_PEER if @ssl_verify_peer
      @client.ssl_config.add_trust_ca(@ca_file) if @ca_file
      @client.ssl_config.set_client_cert_file(@client_cert, @client_key, @client_key_pass) if @client_cert && @client_key
    end

    def format_event(time, record)
      event = @event_key ? (record[@event_key] || '') : record
      msg = {'event' => event}
      msg['time'] = time unless @event_key && !@use_fluentd_time

      # metadata
      msg['sourcetype'] = @sourcetype if @sourcetype

      if record[@host_key]
        msg['host'] = record[@host_key]
      elsif @default_host
        msg['host'] = @default_host
      end

      if record[@source_key]
        msg['source'] = record[@source_key]
      elsif @default_source
        msg['source'] = @default_source
      end

      if record[@index_key]
        msg['index'] = record[@index_key]
      elsif @default_index
        msg['index'] = @default_index
      end

      msg.to_json + @line_breaker
    end

    def format_event_raw(record)
      (record[@event_key] || '') + @line_breaker
    end

    def post(path, body, query = {})
      @client.post(path, body: body, query: query)
    end

    def post_payload(payload)
      res = nil
      if @raw
        res = post('/services/collector/raw', payload, @query)
      else
        res = post('/services/collector', payload)
      end
      log.debug "Splunk response: #{res.body}"
      if @use_ack
        res_json = JSON.parse(res.body)
        ack_id = res_json['ackId']
        check_ack(ack_id, @ack_retry_limit)
      end
    end

    def check_ack(ack_id, retries)
      raise "failed to index the data ack_id=#{ack_id}" if retries < 0

      ack_res = post('/services/collector/ack', {'acks' => [ack_id]}.to_json)
      ack_res_json = JSON.parse(ack_res.body)
      if ack_res_json['acks'] && ack_res_json['acks'][ack_id.to_s]
        return
      else
        sleep(@ack_interval)
        check_ack(ack_id, retries - 1)
      end
    end
  end
end
