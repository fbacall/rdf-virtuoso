require 'httparty'
require 'rdf'
require 'uri'
require 'timeout'

module RDF
  module Virtuoso
    class Repository < ::RDF::Repository
      include HTTParty

      RESULT_JSON = 'application/sparql-results+json'.freeze
      RESULT_XML  = 'application/sparql-results+xml'.freeze

      class Parser::SparqlJson < HTTParty::Parser
        SupportedFormats.merge!({ RESULT_JSON => :json })
      end

      class ClientError < StandardError; end
      class MalformedQuery < ClientError; end
      class NotAuthorized < ClientError; end
      class ServerError < StandardError; end

      #persistent
      maintain_method_across_redirects true

      attr_reader :uri, :update_uri, :username, :password, :auth_method

      def initialize(uri, opts={}, &block)
        @uri             = URI.parse(uri)
        @update_uri      = URI.parse(opts[:update_uri]) if opts[:update_uri]
        @base_uri        = "#{@uri.scheme}://#{@uri.host}"
        @base_uri       += ":" + @uri.port.to_s if @uri.port
        @username        = opts[:username]    || nil
        @password        = opts[:password]    || nil
        @auth_method     = opts[:auth_method] || 'digest'
        @timeout         = opts[:timeout]     || 5 # default timeout 5 seconds

        @sparql_endpoint = @uri.request_uri
        @sparul_endpoint = @update_uri.nil? ? @sparql_endpoint : @update_uri.request_uri
        self.class.base_uri @base_uri
      end

      READ_METHODS  = %w(query select ask construct describe)
      WRITE_METHODS = %w(insert insert_data update delete delete_data create drop clear)

      READ_METHODS.each do |m|
        define_method m do |*args|
          response = api_get *args
        end
      end

      WRITE_METHODS.each do |m|
        define_method m do |*args|
          response = api_post *args
        end
      end

      private

      def check_response_errors(response)
        case response.code
        when 401
          raise NotAuthorized.new
        when 400
          raise MalformedQuery.new(response.parsed_response)
        when 500..599
          raise ServerError.new(response.body)
        end
      end

      def headers
        { 'Accept' => [RESULT_JSON, RESULT_XML].join(', ') }
      end

      def auth_options
        case @auth_method
        when 'basic'
          { basic_auth: auth }
        when 'digest'
          { digest_auth: auth }
        end
      end

      def auth
        { username: @username, password: @password }
      end

      def api_get(query, options = {})
        # prefer sparul endpoint with auth if present to allow SELECT/CONSTRUCT access to protected graphs
        if @sparul_endpoint
          Timeout::timeout(@timeout) do
            response = self.class.get(@sparul_endpoint,
                                      headers: headers,
                                      query: { query: query, format: RESULT_JSON }.merge(options),
                                      **auth_options)
            RDF::Virtuoso::Parser::JSON.call(response)
          end
        else
          Timeout::timeout(@timeout) do
            response = self.class.get(@sparql_endpoint,
                                      headers: headers,
                                      query: { query: query, format: RESULT_JSON }.merge(options))
            RDF::Virtuoso::Parser::JSON.call(response)
          end
        end
      end

      def api_post(query, options = {})
        Timeout::timeout(@timeout) do
          response = self.class.post(@sparul_endpoint,
                                     headers: headers,
                                     query: { format: RESULT_JSON },
                                     body: { query: query }.merge(options),
                                     **auth_options)
          response.dig('results', 'bindings', 0, 'callret-0', 'value')
        end
      end
    end
  end
end
