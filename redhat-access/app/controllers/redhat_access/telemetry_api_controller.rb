require_dependency "redhat_access/application_controller"
require File.expand_path('../../../services/redhat_access/authentication/client_authentication.rb', __FILE__)
require 'rest_client'
require 'redhat_access_lib'

module RedhatAccess

  class Client < RedHatSupportLib::TelemetryApi::Client

    # Returns an array of the machine IDs that this user has access to
    def get_machines
      hosts = resource_base.search_for('').map(&:name)
      #hopefully we can refactor later to optimize
      hosts = hosts.map  do |i|
        host = get_content_host_by_fqdn(i)
        host.nil? ? nil : host.uuid
      end
      hosts.compact.sort
    end

    # Returns the branch id of the current org/account
    def get_branch_id
      #TODO err out if org is not selected
      return get_branch_id_for_org Organization.current
    end

    def get_auth_opts creds
      if creds.is_a?(User) and  User.current.is_a? RedhatAccess::Authentication::CertUser
        opts = get_ssl_options_for_uuid(User.current.login)
      elsif creds.is_a?(TelemetryProxyCredentials)
        opts = {
          :user     => creds[:username],
          :password => creds[:password],
        }
      end

      return opts
    end

    private

    def resource_base
      @resource_base ||= Host.authorized(current_permission, Host)
    end

    def get_content_host_by_fqdn(name)
      Katello::System.first(:conditions => { :name => name})
    end

    def get_branch_id_for_org(org)
      if org
        if !org.owner_details['upstreamConsumer'] || !org.owner_details['upstreamConsumer']['uuid']
          ldebug('Org manifest not found or invalid in get_branch_id')
          raise(RecordNotFound,'Branch ID not found for organization')
        else
          branch_id =  org.owner_details['upstreamConsumer']['uuid']
        end
      else
        ldebug('Org not found or invalid in get_branch_id')
        raise(RecordNotFound,'Organization not found or invalid')
      end
    end

  end








  class TelemetryApiController < ApplicationController

    include RedhatAccess::Authentication::ClientAuthentication

    #TODO clean up filters once the API is split up
    skip_before_filter :authorize,  :except => [:proxy]
    skip_before_filter :require_login, :except => [:proxy]
    skip_before_filter :session_expiry, :except => [:proxy]
    skip_before_filter :verify_authenticity_token, :except => [:proxy]
    before_filter :telemetry_auth


    STRATA_URL = "https://#{REDHAT_ACCESS_CONFIG[:strata_host]}"

    def api_request?
      true
    end

    # Get the credentials to access Strata
    # This is BASIC auth for now, but should use cert auth for GA
    def get_creds
      # enable this once cert auth is fixed:
      # return User

      return TelemetryProxyCredentials.limit(1)[0]
    end

    # The auth method for this controller
    def telemetry_auth
      authenticate_client
      unless  User.current.is_a? RedhatAccess::Authentication::CertUser
        authorize
      end
    end

    def index
      render :text => "Telemetry API"
    end

    # The method that "proxies" tapi requests over to Strata
    # TODO - separate UI api?
    def proxy
      #TODO err out if org is not selected
      original_method   =  request.method
      original_parms    = request.query_parameters
      original_payload  = request.request_parameters[:telemetry_api]
      resource = params[:path].split("/")[0]

      client = Client.new STRATA_URL, get_creds, {:logger => logger}

      res = client.call_tapi(original_method, resource, original_parms, original_payload)

      render status: res[:code], json: res[:data]
    end

    def get_leaf_id(uuid)
      system = get_content_host(uuid)
      if system.nil?
        ldebug('Host not found or invalid')
        raise(RecordNotFound,'Host not found or invalid')
      end
      uuid
    end

    # Get the branch and leaf ID for a client system
    # TODO - separate client machine api?
    def get_client_id
      #TODO check for non cert user
      uuid = User.current.login
      begin
        client_id = { :remote_leaf => uuid ,
                      :remote_branch => get_branch_id_for_uuid(uuid)}
        render :json => client_id.to_json
      rescue RecordNotFound => e
        http_error_response(e.message, 400)
      end
    end

    def action_permission
      case params[:action]
      when 'proxy'
        :proxy
      else
        super
      end
    end

    # Handle uploading dvargas report to strata
    # TODO - separate client machine api?
    def upload_sosreport
      begin
        creds = get_creds
        request = RestClient::Request.new(
          :method => :post,
          :url => UPLOAD_URL,
          :user => creds.username,
          :password => creds.password,
          :payload => {
            :file => params[:file],
            :filename => params[:file].original_filename
          }
        )

        # request[:payload] = {
        #   :file => params[:file],
        #   :filename => params[:file].original_filename
        # }

        response = request.execute
      rescue Exception => e
        message = "Unknown error uploading #{params[:file].original_filename} to #{UPLOAD_URL}: #{e.message}"
        e.backtrace.inspect
        status = 500
        if response
          status = response.code || 500
        end
        render json: { :status => "error", :message => message }, :status => status
        return
      end

      if response.code != 201
        message = "Error uploading #{params[:file].original_filename} to #{UPLOAD_URL}: #{response.description}"
        logger.error message
        status = response.code || 500
        render json: { :status => "error", :message => message }, :status => status
        return
      end

      render json: { :status => "success" }
    end


    # Grabs the PhoneHome YAML conf file
    # TODO - separate client machine api?
    def get_ph_conf
      require 'rest_client'

      begin
        creds = get_creds
        resource = RestClient::Resource.new YAML_URL, :user => creds.username, :password => creds.password
        response = resource.get
      rescue Exception => e
        message = "Unknown error downloading uploader.yml from #{YAML_URL}: #{e.message}"
        e.backtrace.inspect
        render text: message
        return
      end

      if response.code != 200
        message = "Error downloading uploader.yaml from #{YAML_URL}: #{response.description}"
        logger.error message
        render text: message
      end

      render text: response.to_str
    end

    private

    class  RecordNotFound < StandardError
    end

    def http_error_response(msg,status)
      render json: { :message => msg }, :status => status
    end

    def get_ssl_options_for_uuid(uuid)
      org = get_organization(uuid)
      get_ssl_options_for_org org
    end

    def get_ssl_options_for_org(org ,ca_file)
      if org
        upstream = org.owner_details['upstreamConsumer']
        if !upstream || !upstream['idCert'] || !upstream['idCert']['cert'] || !upstream['idCert']['key']
          raise(RecordNotFound,'Unable to get portal SSL credentials. Missing org manifest?')
        else
          opts = {
            :ssl_client_cert => OpenSSL::X509::Certificate.new(upstream['idCert']['cert']),
            :ssl_client_key => OpenSSL::PKey::RSA.new(upstream['idCert']['key']),
            :ssl_ca_file => ca_file,
            :verify_ssl => ca_file ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE,
          }
        end
      else
        raise(RecordNotFound,'Organization not found or invalid')
      end
    end

    def get_branch_id_for_uuid(uuid)
      org = get_organization(uuid)
      get_branch_id_for_org org
    end

    def get_organization(uuid)
      system = get_content_host(uuid)
      system.nil? ? nil : Organization.find(system.environment.organization_id)
    end

    def get_content_host(uuid)
      system = Katello::System.first(:conditions => { :uuid => uuid })
    end

  end
end
