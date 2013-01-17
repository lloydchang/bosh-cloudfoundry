# Copyright (c) 2012-2013 Stark & Wayne, LLC

module Bosh; module CloudFoundry; end; end

# Renders a +SystemConfig+ model into a System's BOSH deployment
# manifest(s).
class Bosh::CloudFoundry::SystemDeploymentManifestRenderer
  include FileUtils
  attr_reader :system_config, :common_config, :bosh_config

  def initialize(system_config, common_config, bosh_config)
    @system_config = system_config
    @common_config = common_config
    @bosh_config = bosh_config
  end

  # Render deployment manifest(s) for a system
  # based on the model data in +system_config+
  # (a +SystemConfig+ object).
  def perform
    validate_system_config

    deployment_name = "#{system_config.system_name}-core"

    manifest = base_manifest(
      deployment_name,
      bosh_config.target_uuid,
      system_config.bosh_provider,
      system_config.system_name,
      system_config.release_name,
      system_config.release_version,
      system_config.stemcell_name,
      system_config.stemcell_version,
      cloud_properties_for_server_flavor(system_config.core_server_flavor),
      system_config.core_ip,
      system_config.root_dns,
      system_config.admin_emails,
      system_config.common_password,
      system_config.common_persistent_disk,
      system_config.aws_security_group
    )

    dea_config.add_core_jobs_to_manifest(manifest)
    dea_config.add_resource_pools_to_manifest(manifest)
    dea_config.add_jobs_to_manifest(manifest)
    dea_config.merge_manifest_properties(manifest)

    postgresql_service_config.add_core_jobs_to_manifest(manifest)
    postgresql_service_config.add_resource_pools_to_manifest(manifest)
    postgresql_service_config.add_jobs_to_manifest(manifest)
    postgresql_service_config.merge_manifest_properties(manifest)

    redis_service_config.add_core_jobs_to_manifest(manifest)
    redis_service_config.add_resource_pools_to_manifest(manifest)
    redis_service_config.add_jobs_to_manifest(manifest)
    redis_service_config.merge_manifest_properties(manifest)

    chdir system_config.system_dir do
      mkdir_p("deployments")
      File.open("deployments/#{system_config.system_name}-core.yml", "w") do |file|
        file << manifest.to_yaml
      end
      # `open "deployments/#{system_config.system_name}-core.yml"`
    end
  end

  def validate_system_config
    s = system_config
    must_not_be_nil = [
      :system_dir,
      :bosh_provider,
      :release_name,
      :release_version,
      :stemcell_name,
      :stemcell_version,
      :core_server_flavor,
      :core_ip,
      :root_dns,
      :admin_emails,
      :common_password,
      :common_persistent_disk,
      :aws_security_group,
    ]
    must_not_be_nil_failures = must_not_be_nil.inject([]) do |list, attribute|
      list << attribute unless system_config.send(attribute)
      list
    end
    if must_not_be_nil_failures.size > 0
      raise "These SystemConfig fields must not be nil: #{must_not_be_nil_failures.inspect}"
    end
  end

  def dea_config
    @dea_config ||= Bosh::CloudFoundry::Config::DeaConfig.build_from_system_config(system_config)
  end

  def postgresql_service_config
    @postgresql_service_config ||= 
      Bosh::CloudFoundry::Config::PostgresqlServiceConfig.build_from_system_config(system_config)
  end

  def redis_service_config
    @redis_service_config ||= 
      Bosh::CloudFoundry::Config::RedisServiceConfig.build_from_system_config(system_config)
  end

  # Converts a server flavor (such as 'm1.large' on AWS) into
  # a BOSH deployment manifest +cloud_properties+ YAML string
  # For AWS & m1.large, it would be:
  #   'instance_type: m1.large'
  def cloud_properties_for_server_flavor(server_flavor)
    if aws?
      { "instance_type" => server_flavor }
    else
      raise 'Please implement #{self.class}#cloud_properties_for_server_flavor'
    end
  end

  def aws?
    system_config.bosh_provider == "aws"
  end

  # 
  def base_manifest(
      deployment_name,
      director_uuid,
      bosh_provider,
      system_name,
      release_name,
      release_version,
      stemcell_name,
      stemcell_version,
      core_cloud_properties,
      core_ip,
      root_dns,
      admin_emails,
      common_password,
      common_persistent_disk,
      aws_security_group
    )
    # This large, terse, pretty-printed manifest can be
    # generated by loading in a spec/assets/deployments/*.yml file
    # and pretty-printing it.
    #
    #   manifest = YAML.load_file('spec/assets/deployments/aws-core-only.yml')
    #   require "pp"
    #   pp manifest
    {"name"=>deployment_name,
     "director_uuid"=>director_uuid,
     "release"=>{"name"=>release_name, "version"=>release_version},
     "compilation"=>
      {"workers"=>10,
       "network"=>"default",
       "reuse_compilation_vms"=>true,
       "cloud_properties"=>{"instance_type"=>"m1.medium"}},
     "update"=>
      {"canaries"=>1,
       "canary_watch_time"=>"30000-150000",
       "update_watch_time"=>"30000-150000",
       "max_in_flight"=>4,
       "max_errors"=>1},
     "networks"=>
      [{"name"=>"default",
        "type"=>"dynamic",
        "cloud_properties"=>{"security_groups"=>[aws_security_group]}},
       {"name"=>"vip_network",
        "type"=>"vip",
        "cloud_properties"=>{"security_groups"=>[aws_security_group]}}],
     "resource_pools"=>
      [{"name"=>"core",
        "network"=>"default",
        "size"=>1,
        "stemcell"=>{"name"=>stemcell_name, "version"=>stemcell_version},
        "cloud_properties"=>core_cloud_properties,
        "persistent_disk"=>common_persistent_disk}],
     "jobs"=>
      [{"name"=>"core",
        "template"=>
         ["postgres",
          "nats",
          "router",
          "health_manager",
          "cloud_controller",
          "acm",
          # "debian_nfs_server",
          # "serialization_data_server",
          "stager",
          "uaa",
          "vcap_redis"],
        "instances"=>1,
        "resource_pool"=>"core",
        "networks"=>
         [{"name"=>"default", "default"=>["dns", "gateway"]},
          {"name"=>"vip_network", "static_ips"=>[core_ip]}],
        "persistent_disk"=>common_persistent_disk}],
     "properties"=>
      {"domain"=>root_dns,
       "env"=>nil,
       "networks"=>{"apps"=>"default", "management"=>"default"},
       "router"=>
        {"client_inactivity_timeout"=>600,
         "app_inactivity_timeout"=>600,
         "local_route"=>core_ip,
         "status"=>
          {"port"=>8080, "user"=>"router", "password"=>common_password}},
       "nats"=>
        {"user"=>"nats",
         "password"=>common_password,
         "address"=>core_ip,
         "port"=>4222},
       "db"=>"ccdb",
       "ccdb"=>
        {"template"=>"postgres",
         "address"=>core_ip,
         "port"=>2544,
         "databases"=>
          [{"tag"=>"cc", "name"=>"appcloud"},
           {"tag"=>"acm", "name"=>"acm"},
           {"tag"=>"uaa", "name"=>"uaa"}],
         "roles"=>
          [{"name"=>"root", "password"=>common_password, "tag"=>"admin"},
           {"name"=>"acm", "password"=>common_password, "tag"=>"acm"},
           {"name"=>"uaa", "password"=>common_password, "tag"=>"uaa"}]},
       "cc"=>
        {"description"=>"Cloud Foundry",
         "srv_api_uri"=>"http://api.#{root_dns}",
         "password"=>common_password,
         "token"=>"TOKEN",
         "allow_debug"=>true,
         "allow_registration"=>true,
         "admins"=>admin_emails,
         "admin_account_capacity"=>
          {"memory"=>2048, "app_uris"=>32, "services"=>16, "apps"=>16},
         "default_account_capacity"=>
          {"memory"=>2048, "app_uris"=>32, "services"=>16, "apps"=>16},
         "new_stager_percent"=>100,
         "staging_upload_user"=>"vcap",
         "staging_upload_password"=>common_password,
         "uaa"=>
          {"enabled"=>true,
           "resource_id"=>"cloud_controller",
           "token_creation_email_filter"=>[""]},
         "service_extension"=>{"service_lifecycle"=>{"max_upload_size"=>5}},
         "use_nginx"=>false},
       "postgresql_server"=>{"max_connections"=>30, "listen_address"=>"0.0.0.0"},
       "acm"=>{"user"=>"acm", "password"=>common_password},
       "acmdb"=>
        {"address"=>core_ip,
         "port"=>2544,
         "roles"=>
          [{"tag"=>"admin", "name"=>"acm", "password"=>common_password}],
         "databases"=>[{"tag"=>"acm", "name"=>"acm"}]},
       # "serialization_data_server"=>
       #  {"upload_token"=>"TOKEN",
       #   "use_nginx"=>false,
       #   "upload_timeout"=>10,
       #   "port"=>8090,
       #   "upload_file_expire_time"=>600,
       #   "purge_expired_interval"=>30},
       "service_lifecycle"=>
        {"download_url"=>core_ip,
         "mount_point"=>"/var/vcap/service_lifecycle",
         "tmp_dir"=>"/var/vcap/service_lifecycle/tmp_dir",
         "resque"=>
          {"host"=>core_ip, "port"=>3456, "password"=>common_password},
         # "nfs_server"=>{"address"=>core_ip, "export_dir"=>"/cfsnapshot"},
         # "serialization_data_server"=>[core_ip]
        },
       "stager"=>
        {"max_staging_duration"=>120,
         "max_active_tasks"=>20,
         "queues"=>["staging"]},
       "uaa"=>
        {"cc"=>{"token_secret"=>"TOKEN_SECRET", "client_secret"=>"CLIENT_SECRET"},
         "admin"=>{"client_secret"=>"CLIENT_SECRET"},
         "login"=>{"client_secret"=>"CLIENT_SECRET"},
         "batch"=>{"username"=>"uaa", "password"=>common_password},
         "port"=>8100,
         "catalina_opts"=>"-Xmx128m -Xms30m -XX:MaxPermSize=128m",
         "no_ssl"=>true},
       "uaadb"=>
        {"address"=>core_ip,
         "port"=>2544,
         "roles"=>
          [{"tag"=>"admin", "name"=>"uaa", "password"=>common_password}],
         "databases"=>[{"tag"=>"uaa", "name"=>"uaa"}]},
       "vcap_redis"=>
        {"address"=>core_ip,
         "port"=>3456,
         "password"=>common_password,
         "maxmemory"=>500000000},
       "service_plans"=>{},
       "dea"=>{"max_memory"=>512}}}
  end

end
