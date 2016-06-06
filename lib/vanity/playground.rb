require "uri"

module Vanity

  # Playground catalogs all your experiments, holds the Vanity configuration.
  #
  # @example
  #   Vanity.playground.logger = my_logger
  #   puts Vanity.playground.map(&:name)
  class Playground

    DEFAULTS = { :collecting => true, :load_path=>"experiments" }
    DEFAULT_ADD_PARTICIPANT_PATH = '/vanity/add_participant'

    # Created new Playground. Unless you need to, use the global
    # Vanity.playground.
    #
    # First argument is connection specification (see #redis=), last argument is
    # a set of options, both are optional. Supported options are:
    # - connection -- Connection specification
    # - load_path -- Path to load experiments/metrics from
    # - logger -- Logger to use
    # - redis -- A Redis object that will be used for the connection
    def initialize(*args)
      options = Hash === args.last ? args.pop : {}
      # In the case of Rails, use the Rails logger and collect only for
      # production environment by default.
      defaults = options[:rails] ? DEFAULTS.merge(:collecting => true, :logger => ::Rails.logger) : DEFAULTS
      if config_file_exists?
        env = ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
        config = load_config_file[env]
        if Hash === config
          config = config.inject({}) { |h,kv| h[kv.first.to_sym] = kv.last ; h }
        else
          config = { :connection=>config }
        end
      else
        config = {}
      end

      @options = defaults.merge(config).merge(options)

      @load_path = @options[:load_path] || DEFAULTS[:load_path]

      I18n.load_path += locale_file_paths
      unless @logger = @options[:logger]
        @logger = Logger.new(STDOUT)
        @logger.level = Logger::ERROR
      end

      autoconnect(@options, args) if Vanity::Autoconnect.playground_should_autoconnect?

      @loading = []
      @use_js = false
      @failover_on_datastore_error = false
      self.add_participant_path = DEFAULT_ADD_PARTICIPANT_PATH
      @collecting = !!@options[:collecting]
      metrics
      experiments
    end

    # Path to load experiment files from.
    attr_accessor :load_path

    # Logger.
    attr_accessor :logger

    # Path to the add_participant action.
    attr_accessor :add_participant_path

    attr_accessor :on_datastore_error

    attr_accessor :request_filter

    # Path to custom templates (overriding those in the gem)
    attr_writer :custom_templates_path
    def custom_templates_path
      @custom_templates_path ||= (File.expand_path(File.join(::Rails.root, 'app', 'views', 'vanity')) if defined?(::Rails))
    end

    # Returns the experiment. You may not have guessed, but this method raises
    # an exception if it cannot load the experiment's definition.
    #
    # @see Vanity::Experiment
    def experiment(name)
      id = name.to_s.downcase.gsub(/\W/, "_").to_sym
      warn "Deprecated: please call experiment method with experiment identifier (a Ruby symbol)" unless id == name
      experiments[id.to_sym] or raise NoExperimentError, "No experiment #{id}"
    end


    # -- Participant Information --

    # Returns an array of all experiments this participant is involved in, with their assignment.
    #  This is done as an array of arrays [[<experiment_1>, <assignment_1>], [<experiment_2>, <assignment_2>]], sorted by experiment name, so that it will give a consistent string
    #  when converted to_s (so could be used for caching, for example)
    def participant_info(participant_id)
      participant_array = []
      experiments.values.sort_by(&:name).each do |e|
        index = connection.ab_assigned(e.id, participant_id)
        if index
          participant_array << [e, e.alternatives[index.to_i]]
        end
      end
      participant_array
    end


    # -- Robot Detection --

    # Call to indicate that participants should be added via js. This helps
    # keep robots from participating in the A/B test and skewing results.
    #
    # If you want to use this:
    # - Add <%= vanity_js %> to any page that needs uses an ab_test. vanity_js
    #   needs to be included after your call to ab_test so that it knows which
    #   version of the experiment the participant is a member of. The helper
    #   will render nothing if the there are no ab_tests running on the current
    #   page, so adding vanity_js to the bottom of your layouts is a good
    #   option. Keep in mind that if you call use_js! and don't include
    #   vanity_js in your view no participants will be recorded.
    #
    # Note that a custom JS callback path can be set using:
    # - Set Vanity.playground.add_participant_path = '/path/to/vanity/action',
    #   this should point to the add_participant path that is added with
    #   Vanity::Rails::Dashboard, make sure that this action is available
    #   to all users.
    def use_js!
      @use_js = true
    end

    def using_js?
      @use_js
    end


    # -- Datastore graceful failover --

    # Turns on passing of errors to the Proc returned by #on_datastore_error.
    # Call Vanity.playground.failover_on_datastore_error! to turn this on.
    #
    # @since 1.9.0
    def failover_on_datastore_error!
      @failover_on_datastore_error = true
    end

    # Returns whether to failover on an error raise by the datastore adapter.
    #
    # @since 1.9.0
    def failover_on_datastore_error?
      @failover_on_datastore_error
    end

    # Must return a Proc that accepts as parameters: the thrown error, the
    # calling Class, the calling method, and an array of arguments passed to
    # the calling method. The return value is ignored.
    #
    #    Proc.new do |error, klass, method, arguments|
    #      ...
    #    end
    #
    # The default implementation logs this information to Playground#logger.
    #
    # Set a custom action by calling Vanity.playground.on_datastore_error =
    # Proc.new { ... }.
    #
    # @since 1.9.0
    def on_datastore_error
      @on_datastore_error || default_on_datastore_error
    end

    def default_on_datastore_error # :nodoc:
      Proc.new do |error, klass, method, arguments|
        log = "[#{Time.now.iso8601}]"
        log << " [vanity #{klass} #{method}]"
        log << " [#{error.message}]"
        log << " [#{arguments.join(' ')}]"
        @logger.error(log)
        nil
      end
    end
    protected :default_on_datastore_error


    # -- Blocking or ignoring visitors --

    # Must return a Proc that accepts as a parameter the request object, if
    # made available by the implement framework. The return value should be a
    # boolean whether to ignore the request. This is called only for the JS
    # callback action.
    #
    #    Proc.new do |request|
    #      ...
    #    end
    #
    # The default implementation does a simple test of whether the request's
    # HTTP_USER_AGENT header contains a URI, since well behaved bots typically
    # include a reference URI in their user agent strings. (Original idea:
    # http://stackoverflow.com/a/9285889.)
    #
    # Alternatively, one could filter an explicit list of IPs, add additional
    # user agent strings to filter, or any custom test. Set a custom filter
    # by calling Vanity.playground.request_filter = Proc.new { ... }.
    #
    # @since 1.9.0
    def request_filter
      @request_filter || default_request_filter
    end

    def default_request_filter # :nodoc:
      Proc.new do |request|
        request &&
          request.env &&
          request.env["HTTP_USER_AGENT"] &&
          request.env["HTTP_USER_AGENT"].match(/\(.*https?:\/\/.*\)/)
      end
    end
    protected :default_request_filter

    # Returns hash of experiments (key is experiment id). This create the
    # Experiment and persists it to the datastore.
    #
    # @see Vanity::Experiment
    def experiments
      return @experiments if @experiments

      @experiments = {}
      @logger.info "Vanity: loading experiments from #{load_path}"
      Dir[File.join(load_path, "*.rb")].each do |file|
        Experiment::Base.load(self, @loading, file)
      end
      @experiments
    end

    def experiments_persisted?
      experiments.keys.all? { |id| connection.experiment_persisted?(id) }
    end

    # Reloads all metrics and experiments. Rails calls this for each request in
    # development mode.
    def reload!
      @experiments = nil
      @metrics = nil
      load!
    end

    # Loads all metrics and experiments. Rails calls this during
    # initialization.
    def load!
      experiments
      metrics
    end

    # Returns a metric (raises NameError if no metric with that identifier).
    #
    # @see Vanity::Metric
    # @since 1.1.0
    def metric(id)
      metrics[id.to_sym] or raise NameError, "No metric #{id}"
    end

    # True if collection data (metrics and experiments). You only want to
    # collect data in production environment, everywhere else run with
    # collection off.
    #
    # @since 1.4.0
    def collecting?
      @collecting
    end

    # Turns data collection on and off.
    #
    # @since 1.4.0
    def collecting=(enabled)
      @collecting = !!enabled
    end

    # Returns hash of metrics (key is metric id).
    #
    # @see Vanity::Metric
    # @since 1.1.0
    def metrics
      unless @metrics
        @metrics = {}
        @logger.info "Vanity: loading metrics from #{load_path}/metrics"
        Dir[File.join(load_path, "metrics/*.rb")].each do |file|
          Metric.load self, @loading, file
        end
        if config_file_exists? && remote = load_config_file["metrics"]
          remote.each do |id, url|
            fail "Metric #{id} already defined in playground" if metrics[id.to_sym]
            metric = Metric.new(self, id)
            metric.remote url
            metrics[id.to_sym] = metric
          end
        end
      end
      @metrics
    end

    # Tracks an action associated with a metric.
    #
    # @example
    #   Vanity.playground.track! :uploaded_video
    #
    # @since 1.1.0
    def track!(id, count = 1)
      metric(id).track! count
    end


    # -- Connection management --

    # This is the preferred way to programmatically create a new connection (or
    # switch to a new connection). If no connection was established, the
    # playground will create a new one by calling this method with no arguments.
    #
    # With no argument, uses the connection specified in config/vanity.yml file
    # for the current environment (RACK_ENV, RAILS_ENV or development). If there
    # is no config/vanity.yml file, picks the configuration from
    # config/redis.yml, or defaults to Redis on localhost, port 6379.
    #
    # If the argument is a symbol, uses the connection specified in
    # config/vanity.yml for that environment. For example:
    #   Vanity.playground.establish_connection :production
    #
    # If the argument is a string, it is processed as a URL. For example:
    #   Vanity.playground.establish_connection "redis://redis.local/5"
    #
    # Otherwise, the argument is a hash and specifies the adapter name and any
    # additional options understood by that adapter (as with config/vanity.yml).
    # For example:
    #   Vanity.playground.establish_connection :adapter=>:redis,
    #                                          :host=>"redis.local"
    #
    # @since 1.4.0
    def establish_connection(spec = nil)
      @spec = spec
      disconnect! if @adapter
      case spec
      when nil
        if config_file_exists?
          env = ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
          spec = load_config_file[env]
          fail "No configuration for #{env}" unless spec
          establish_connection spec
        elsif config_file_exists?("redis.yml")
          env = ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development"
          redis = load_config_file("redis.yml")[env]
          fail "No configuration for #{env}" unless redis
          establish_connection "redis://" + redis
        else
          establish_connection :adapter=>"redis"
        end
      when Symbol
        spec = load_config_file[spec.to_s]
        establish_connection spec
      when String
        uri = URI.parse(spec)
        params = CGI.parse(uri.query) if uri.query
        establish_connection :adapter=>uri.scheme, :username=>uri.user, :password=>uri.password,
          :host=>uri.host, :port=>uri.port, :path=>uri.path, :params=>params
      else
        spec = spec.inject({}) { |hash,(k,v)| hash[k.to_sym] = v ; hash }
        @adapter = Adapters.establish_connection(spec)
      end
    end

    def config_file_root
      (defined?(::Rails) ? ::Rails.root : Pathname.new(".")) + "config"
    end

    def config_file_exists?(basename = "vanity.yml")
      File.exists?(config_file_root + basename)
    end

    def load_config_file(basename = "vanity.yml")
      YAML.load(ERB.new(File.read(config_file_root + basename)).result)
    end

    def locale_file_paths
      locale_files_dir = File.expand_path('../../config/locales/', File.dirname(__FILE__))
      Dir[locale_files_dir+'/*.{rb,yml}']
    end

    # Returns the current connection. Establishes new connection is necessary.
    #
    # @since 1.4.0
    def connection
      @adapter || establish_connection
    end

    # Returns true if connection is open.
    #
    # @since 1.4.0
    def connected?
      @adapter && @adapter.active?
    end

    # Closes the current connection.
    #
    # @since 1.4.0
    def disconnect!
      @adapter.disconnect! if @adapter
    end

    # Closes the current connection and establishes a new one.
    #
    # @since 1.3.0
    def reconnect!
      establish_connection(@spec)
    end

    protected

    def autoconnect(options, arguments)
      if options[:redis]
        @adapter = RedisAdapter.new(:redis=>options[:redis])
      else
        connection_spec = arguments.shift || options[:connection]
        if connection_spec
          connection_spec = "redis://" + connection_spec unless connection_spec[/^\w+:/]
          establish_connection connection_spec
        else
          establish_connection
        end
      end
    end

  end

  # In the case of Rails, use the Rails logger and collect only for
  # production environment by default.
  class << self

    # The playground instance.
    #
    # @see Vanity::Playground
    attr_accessor :playground
    def playground
      # In the case of Rails, use the Rails logger and collect only for
      # production environment by default.
      @playground ||= Playground.new(:rails=>defined?(::Rails))
    end

    # Returns the Vanity context. For example, when using Rails this would be
    # the current controller, which can be used to get/set the vanity identity.
    def context
      Thread.current[:vanity_context]
    end

    # Sets the Vanity context. For example, when using Rails this would be
    # set by the set_vanity_context before filter (via Vanity::Rails#use_vanity).
    def context=(context)
      Thread.current[:vanity_context] = context
    end


  end
end
