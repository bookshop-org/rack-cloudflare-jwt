# frozen_string_literal: true

require 'jwt'
require 'multi_json'
require 'net/http'
require 'rack/jwt'

module Rack
  module CloudflareJwt
    # Authentication middleware
    #
    # @see https://developers.cloudflare.com/access/setting-up-access/validate-jwt-tokens/
    class Auth
      # Certs path
      CERTS_PATH = '/cdn-cgi/access/certs'
      # Default algorithm
      DEFAULT_ALGORITHM = 'RS256'
      # CloudFlare JWT header.
      HEADER_NAME = 'HTTP_CF_ACCESS_JWT_ASSERTION'

      # Token regex.
      #
      # @see https://github.com/jwt/ruby-jwt/tree/v2.2.1#algorithms-and-usage
      TOKEN_REGEX = /
        ^(
        [a-zA-Z0-9\-\_]+\.  # 1 or more chars followed by a single period
        [a-zA-Z0-9\-\_]+\.  # 1 or more chars followed by a single period
        [a-zA-Z0-9\-\_]+    # 1 or more chars, no trailing chars
        )$
      /x.freeze

      attr_reader :policy_aud, :include_paths

      # Initializes middleware
      def initialize(app, opts = {})
        @app           = app
        @policy_aud    = opts.fetch(:policy_aud, nil)
        @include_paths = opts.fetch(:include_paths, [])

        check_policy_aud!
        check_include_paths_type!
      end

      # Public: Call a middleware.
      def call(env)
        if !path_matches_include_paths?(env)
          @app.call(env)
        elsif missing_auth_header?(env)
          return_error('Missing Authorization header')
        elsif invalid_auth_header?(env)
          return_error('Invalid Authorization header format')
        else
          verify_token(env)
        end
      end

      private

      # Private: Check policy aud.
      def check_policy_aud!
        return unless !policy_aud.is_a?(String) || policy_aud.strip.empty?

        raise ArgumentError, 'policy_aud argument cannot be nil/empty'
      end

      # Private: Check include_paths type.
      def check_include_paths_type!
        raise ArgumentError, 'include_paths argument must be an Array' unless include_paths.is_a?(Array)

        include_paths.each do |path|
          raise ArgumentError, 'each include_paths Array element must be a String' unless path.is_a?(String)
          raise ArgumentError, 'each include_paths Array element must not be empty' if path.empty?
          raise ArgumentError, 'each include_paths Array element must start with a /' unless path.start_with?('/')
        end
      end

      # Private: Verify a token.
      def verify_token(env)
        # extract the token from header.
        token         = env[HEADER_NAME]
        decoded_token = public_keys(env).find do |key|
          dt = decode_token(token, key.public_key)
          break dt if dt
        end

        if decoded_token
          env['jwt.payload'] = decoded_token.first
          env['jwt.header']  = decoded_token.last
          @app.call(env)
        else
          return_error('Invalid token')
        end
      end

      # Private: Decode a token.
      #
      # Example:
      #
      #   [
      #     {"data"=>"test"}, # payload
      #     {"alg"=>"RS256"} # header
      #   ]
      #
      # @return [Array<Hash>] the token.
      # @see https://github.com/jwt/ruby-jwt/tree/v2.2.1#algorithms-and-usage
      def decode_token(token, secret)
        Rack::JWT::Token.decode(token, secret, true, aud: policy_aud, verify_aud: true, algorithm: DEFAULT_ALGORITHM)
      rescue ::JWT::VerificationError
        Rails.logger.info 'Invalid JWT token : Signature Verification Error'
      rescue ::JWT::ExpiredSignature
        Rails.logger.info 'Invalid JWT token : Expired Signature (exp)'
      rescue ::JWT::IncorrectAlgorithm
        Rails.logger.info 'Invalid JWT token : Incorrect Key Algorithm'
      rescue ::JWT::ImmatureSignature
        Rails.logger.info 'Invalid JWT token : Immature Signature (nbf)'
      rescue ::JWT::InvalidIssuerError
        Rails.logger.info 'Invalid JWT token : Invalid Issuer (iss)'
      rescue ::JWT::InvalidIatError
        Rails.logger.info 'Invalid JWT token : Invalid Issued At (iat)'
      rescue ::JWT::InvalidAudError
        Rails.logger.info 'Invalid JWT token : Invalid Audience (aud)'
      rescue ::JWT::InvalidSubError
        Rails.logger.info 'Invalid JWT token : Invalid Subject (sub)'
      rescue ::JWT::InvalidJtiError
        Rails.logger.info 'Invalid JWT token : Invalid JWT ID (jti)'
      rescue ::JWT::DecodeError
        Rails.logger.info 'Invalid JWT token : Decode Error'
      end

      # Private: Check if current path is in the include_paths.
      #
      # @return [Boolean] true if it is, false otherwise.
      def path_matches_include_paths?(env)
        include_paths.empty? || include_paths.any? { |ex| env['PATH_INFO'].start_with?(ex) }
      end

      # Private: Check if auth header is invalid.
      #
      # @return [Boolean] true if it is, false otherwise.
      def invalid_auth_header?(env)
        env[HEADER_NAME] !~ TOKEN_REGEX
      end

      # Private: Check if no auth header.
      #
      # @return [Boolean] true if it is, false otherwise.
      def missing_auth_header?(env)
        env[HEADER_NAME].nil? || env[HEADER_NAME].strip.empty?
      end

      # Private: Return an error.
      def return_error(message)
        body    = { error: message }.to_json
        headers = { 'Content-Type' => 'application/json' }

        [403, headers, [body]]
      end

      # Private: Get public keys.
      #
      # @return [Array<OpenSSL::PKey::RSA>] the public keys.
      def public_keys(env)
        host = env['HTTP_HOST']
        keys = Rails.cache.fetch([self.class.name, '#secrets', host]) { fetch_public_keys(host) }
        keys.map do |jwk_data|
          ::JWT::JWK.import(jwk_data).keypair
        end
      end

      # Private: Fetch public keys.
      #
      # @param host [String] The host.
      #
      # @return [Array<Hash>] the public keys.
      def fetch_public_keys(host)
        json = Net::HTTP.get(host, CERTS_PATH)
        json.present? ? MultiJson.load(json, symbolize_keys: true).fetch(:keys) : []
      rescue StandardError
        []
      end
    end
  end
end