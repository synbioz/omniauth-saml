require 'omniauth'
require 'ruby-saml'

module OmniAuth
  module Strategies
    class SAML
      include OmniAuth::Strategy

      def self.inherited(subclass)
        OmniAuth::Strategy.included(subclass)
      end

      OTHER_REQUEST_OPTIONS = [:skip_conditions, :allowed_clock_drift, :matches_request_id, :skip_subject_confirmation].freeze

      option :name_identifier_format, nil
      option :idp_sso_target_url_runtime_params, {}
      option :request_attributes, [
        { :name => 'email', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Email address' },
        { :name => 'name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Full name' },
        { :name => 'first_name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Given name' },
        { :name => 'last_name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Family name' }
      ]
      option :attribute_service_name, 'Required attributes'
      option :attribute_statements, {
        name: ["name"],
        email: ["email", "mail"],
        first_name: ["first_name", "firstname", "firstName"],
        last_name: ["last_name", "lastname", "lastName"]
      }
      option :default_relay_state

      def request_phase
        options[:assertion_consumer_service_url] ||= callback_url
        runtime_request_parameters = options.delete(:idp_sso_target_url_runtime_params)

        additional_params = {}
        runtime_request_parameters.each_pair do |request_param_key, mapped_param_key|
          additional_params[mapped_param_key] = request.params[request_param_key.to_s] if request.params.has_key?(request_param_key.to_s)
        end if runtime_request_parameters

        authn_request = OneLogin::RubySaml::Authrequest.new
        settings = OneLogin::RubySaml::Settings.new(options)

        redirect(authn_request.create(settings, additional_params))
      end

      def callback_phase
        # Call a fingerprint validation method if there's one
        if options.idp_cert_fingerprint_validator
          fingerprint_exists = options.idp_cert_fingerprint_validator[response_fingerprint]
          unless fingerprint_exists
            raise OmniAuth::Strategies::SAML::ValidationError.new("Non-existent fingerprint")
          end
          # id_cert_fingerprint becomes the given fingerprint if it exists
          options.idp_cert_fingerprint = fingerprint_exists
        end

        settings = OneLogin::RubySaml::Settings.new(options)
        # filter options to select only extra parameters
        opts = options.select {|k,_| OTHER_REQUEST_OPTIONS.include?(k.to_sym)}
        # symbolize keys without activeSupport/symbolize_keys (ruby-saml use symbols)
        opts =
          opts.inject({}) do |new_hash, (key, value)|
            new_hash[key.to_sym] = value
            new_hash
          end

        if request.params["SAMLResponse"]
          handle_response(request.params["SAMLResponse"], opts, settings) do
            super
          end
        else
          raise OmniAuth::Strategies::SAML::ValidationError.new("SAML response missing")
        end

      rescue OmniAuth::Strategies::SAML::ValidationError
        fail!(:invalid_ticket, $!)
      rescue OneLogin::RubySaml::ValidationError
        fail!(:invalid_ticket, $!)
      end

      # Obtain an idp certificate fingerprint from the response.
      def response_fingerprint
        response = request.params['SAMLResponse']
        response = (response =~ /^</) ? response : Base64.decode64(response)
        document = XMLSecurity::SignedDocument::new(response)
        cert_element = REXML::XPath.first(document, "//ds:X509Certificate", { "ds"=> 'http://www.w3.org/2000/09/xmldsig#' })
        base64_cert = cert_element.text
        cert_text = Base64.decode64(base64_cert)
        cert = OpenSSL::X509::Certificate.new(cert_text)
        Digest::SHA1.hexdigest(cert.to_der).upcase.scan(/../).join(':')
      end

      def on_metadata_path?
        on_subpath?(:metadata)
      end

      def other_phase
        if current_path.start_with?(request_path)
          @env['omniauth.strategy'] ||= self
          setup_phase
          settings = OneLogin::RubySaml::Settings.new(options)

          if on_metadata_path?
            # omniauth does not set the strategy on the other_phase
            response = OneLogin::RubySaml::Metadata.new
            if options.request_attributes.length > 0
              settings.attribute_consuming_service.service_name options.attribute_service_name
              settings.issuer = options.issuer
              options.request_attributes.each do |attribute|
                settings.attribute_consuming_service.add_attribute attribute
              end
            end
            Rack::Response.new(response.generate(settings), 200, { "Content-Type" => "application/xml" }).finish
          elsif on_subpath?(:slo)
            if request.params["SAMLResponse"]
              handle_logout_response(request.params["SAMLResponse"], settings)
            elsif request.params["SAMLRequest"]
              handle_logout_request(request.params["SAMLRequest"], settings)
            else
              raise OmniAuth::Strategies::SAML::ValidationError.new("SAML logout response/request missing")
            end
          elsif on_subpath?(:spslo)
            if options.idp_slo_target_url
              redirect(generate_logout_request(settings))
            else
              Rack::Response.new("Not Implemented", 501, { "Content-Type" => "text/html" }).finish
            end
          else
            call_app!
          end
        else
          call_app!
        end
      end

      uid { @name_id }

      info do
        found_attributes = options.attribute_statements.map do |key, values|
          attribute = find_attribute_by(values)
          [key, attribute]
        end

        Hash[found_attributes]
      end

      extra { { :raw_info => @attributes, :response_object =>  @response_object } }

      def find_attribute_by(keys)
        keys.each do |key|
          return @attributes[key] if @attributes[key]
        end

        nil
      end

      private

      def on_subpath?(subpath)
        on_path?("#{request_path}/#{subpath}")
      end

      def handle_response(raw_response, opts, settings)
        response = OneLogin::RubySaml::Response.new(raw_response, opts.merge(settings: settings))
        response.attributes["fingerprint"] = options.idp_cert_fingerprint
        response.soft = false

        response.is_valid?
        @name_id = response.name_id
        @attributes = response.attributes
        @response_object = response

        if @name_id.nil? || @name_id.empty?
          raise OmniAuth::Strategies::SAML::ValidationError.new("SAML response missing 'name_id'")
        end

        session["saml_uid"] = @name_id
        yield
      end

      def relay_state
        if request.params.has_key?("RelayState") && request.params["RelayState"] != ""
          request.params["RelayState"]
        else
          default_relay_state = options.default_relay_state
          if default_relay_state.respond_to?(:call)
            if default_relay_state.arity == 1
              default_relay_state.call(request)
            else
              default_relay_state.call
            end
          else
            default_relay_state
          end
        end
      end

      def handle_logout_response(raw_response, settings)
        # After sending an SP initiated LogoutRequest to the IdP, we need to accept
        # the LogoutResponse, verify it, then actually delete our session.

        logout_response = OneLogin::RubySaml::Logoutresponse.new(raw_response, settings, :matches_request_id => session["saml_transaction_id"])
        logout_response.soft = false
        logout_response.validate

        session.delete("saml_uid")
        session.delete("saml_transaction_id")

        redirect(relay_state)
      end

      def handle_logout_request(raw_request, settings)
        logout_request = OneLogin::RubySaml::SloLogoutrequest.new(raw_request)

        if logout_request.is_valid? &&
          logout_request.name_id == session["saml_uid"]

          # Actually log out this session
          session.clear

          # Generate a response to the IdP.
          logout_request_id = logout_request.id
          logout_response = OneLogin::RubySaml::SloLogoutresponse.new.create(settings, logout_request_id, nil, RelayState: relay_state)
          redirect(logout_response)
        else
          raise OmniAuth::Strategies::SAML::ValidationError.new("SAML failed to process LogoutRequest")
        end
      end

      # Create a SP initiated SLO: https://github.com/onelogin/ruby-saml#single-log-out
      def generate_logout_request(settings)
        logout_request = OneLogin::RubySaml::Logoutrequest.new()

        # Since we created a new SAML request, save the transaction_id
        # to compare it with the response we get back
        session["saml_transaction_id"] = logout_request.uuid

        if settings.name_identifier_value.nil?
          settings.name_identifier_value = session["saml_uid"]
        end

        logout_request.create(settings, RelayState: relay_state)
      end
    end
  end
end

OmniAuth.config.add_camelization 'saml', 'SAML'
