if ENV['DYNFLOW_PATH']
  $:.unshift(ENV['DYNFLOW_PATH'])
elsif File.exists?('./lib/dynflow.rb')
  $:.unshift('./lib')
end

begin
  require 'dynflow'
  require 'dynflow/version'
rescue LoadError => e
  puts e
  puts <<EOF
Dynflow source code not present. Install the version of Dynflow you want
to benchmark, set DYNFLOW_PATH to the path where the source is located or
run the executable from the Dynflow directory.

On Foreman system, you might want to run

    scl enable tfm bash
EOF
end

module LoggerHelper
  def logger
    @__logger ||= Logger.new(STDERR).tap do |logger|
      if $DYNFLOW_EXAMPLE_VERBOSE
        logger.level = Logger::DEBUG
      else
        logger.level = Logger::INFO
      end
      logger.formatter = proc do |severity, datetime, progname, msg|
        s = severity[0...1]
        date_format = datetime.strftime("%H:%M:%S")
        "#{s} [#{date_format}]: #{msg}\n"
      end
    end
  end
end

class BenchmarkHelper
  class << self
    include LoggerHelper
    def set_world(world)
      @world = world
    end

    def create_world
      config = Dynflow::Config.new
      config.persistence_adapter = persistence_adapter
      config.logger_adapter      = logger_adapter
      config.auto_rescue         = false
      config.auto_execute        = false
      if Gem::Version.new(Dynflow::VERSION) >= Gem::Version.new('1.1')
        config.telemetry_adapter   = telemetry_adapter
      end
      yield config if block_given?
      Dynflow::World.new(config)
    end

    def telemetry_adapter
      if (host = ENV['TELEMETRY_STATSD_HOST'])
        Dynflow::TelemetryAdapters::StatsD.new host
      else
        Dynflow::TelemetryAdapters::Dummy.new
      end
    end

    def logger_adapter
      Dynflow::LoggerAdapters::Simple.new $stderr, $DYNFLOW_EXAMPLE_VERBOSE ? 1 : 4
    end

    def run_web_console(world)
      require 'dynflow/web'
      dynflow_console = Dynflow::Web.setup do
        set :world, world
      end
      require 'webrick'
      logger = Logger.new(STDERR)
      logger.level = Logger::ERROR
      @console = ::WEBrick::HTTPServer.new(:Logger => logger, :Port => 4567)
      @console.mount "/", Rack::Handler::WEBrick, dynflow_console
      @console.start
    end

    def terminate
      if @console
        logger.debug "Terminating http console"
        @console.shutdown
        @console = nil
      end
      if @world
        logger.debug "Terminating world #{@world.id}"
        @world.terminate.wait
        logger.debug "World #{@world.id} termination finished"
      end
    end

    def run_observer
      world = create_world do |config|
        config.persistence_adapter = persistence_adapter
        config.connector           = connector
        config.executor            = false
      end
      set_world(world)
      logger.debug "Observer #{world.id} started"
      puts "The console is available at http://localhost:4567"
      run_web_console(world)
    end

    def run_executor
      world = create_world do |config|
        config.persistence_adapter = persistence_adapter
        config.connector           = connector
      end
      set_world(world)
      logger.info "Executor #{world.id} started"
      world.terminated.wait
    end

    def create_client
       create_world do |config|
        config.persistence_adapter = persistence_adapter
        config.executor            = false
        config.connector           = connector
        config.exit_on_terminate   = false
      end
    end

    def db_path
      File.expand_path("../remote_executor_db.sqlite", __FILE__)
    end

    def persistence_conn_string
      ENV['DB_CONN_STRING'] || "sqlite://#{db_path}"
    end

    def persistence_adapter
      Dynflow::PersistenceAdapters::Sequel.new persistence_conn_string
    end

    def connector
      Proc.new { |world| Dynflow::Connectors::Database.new(world) }
    end
  end
end

at_exit { BenchmarkHelper.terminate }

trap(:INT) do
  # for cases the happy path doesn't work well
  if $already_interrupted
    Thread.new { Kernel.exit }
  else
    $already_interrupted = true
    Thread.new { BenchmarkHelper.terminate }
  end
end
