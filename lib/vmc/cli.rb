require "yaml"
require "socket"
require "net/http"
require "multi_json"
require "fileutils"

require "mothership"

require "cfoundry"

require "vmc/constants"
require "vmc/errors"
require "vmc/spacing"

require "vmc/cli/help"
require "vmc/cli/interactive"


$vmc_asked_auth = false

module VMC
  class CLI < Mothership
    include VMC::Interactive
    include VMC::Spacing

    option :help, :alias => "-h", :type => :boolean,
      :desc => "Show command usage & instructions"

    option :proxy, :alias => "-u", :value => :email,
      :desc => "Act as another user (admin only)"

    option :version, :alias => "-v", :type => :boolean,
      :desc => "Print version number"

    option :verbose, :alias => "-V", :type => :boolean,
      :desc => "Print extra information"

    option :force, :alias => "-f", :type => :boolean,
      :default => proc { input[:script] },
      :desc => "Skip interaction when possible"

    option :quiet, :alias => "-q", :type => :boolean,
      :default => proc { input[:script] },
      :desc => "Simplify output format"

    option :script, :type => :boolean,
      :default => proc { !$stdout.tty? },
      :desc => "Shortcut for --quiet and --force"

    option :color, :type => :boolean,
      :default => proc { !input[:quiet] },
      :desc => "Use colorful output"

    option :trace, :alias => "-t", :type => :boolean,
      :desc => "Show API requests and responses"


    def default_action
      if input[:version]
        line "vmc #{VERSION}"
      else
        super
      end
    end

    def check_target
      unless File.exists? target_file
        fail "Please select a target with 'vmc target'."
      end
    end

    def check_logged_in
      unless client.logged_in?
        if force?
          fail "Please log in with 'vmc login'."
        else
          line c("Please log in with 'vmc login'.", :warning)
          line
          invoke :login
          invalidate_client
        end
      end
    end

    def precondition
      check_target
      check_logged_in

      return unless v2?

      unless client.current_organization
        fail "Please select an organization with 'vmc target --ask-org'."
      end

      unless client.current_space
        fail "Please select a space with 'vmc target --ask-space'."
      end
    end

    def execute(cmd, argv, global = {})
      if input[:help]
        invoke :help, :command => cmd.name.to_s
      else
        @command = cmd
        precondition
        super
      end
    rescue Interrupt
      exit_status 130
    rescue Mothership::Error
      raise
    rescue UserError => e
      log_error(e)
      err e.message
    rescue SystemExit
      raise
    rescue CFoundry::Forbidden, CFoundry::InvalidAuthToken => e
      if !$vmc_asked_auth
        $vmc_asked_auth = true

        line
        line c("Not authenticated! Try logging in:", :warning)

        invoke :login

        retry
      end

      log_error(e)

      err "Denied: #{e.description}"

    rescue Exception => e
      ensure_config_dir

      log_error(e)

      msg = e.class.name
      msg << ": #{e}" unless e.to_s.empty?
      msg << "\nFor more information, see #{VMC::CRASH_FILE}"
      err msg
    end

    def log_error(e)
      msg = e.class.name
      msg << ": #{e}" unless e.to_s.empty?

      crash_file = File.expand_path(VMC::CRASH_FILE)

      FileUtils.mkdir_p(File.dirname(crash_file))

      File.open(crash_file, "w") do |f|
        f.puts "Time of crash:"
        f.puts "  #{Time.now}"
        f.puts ""
        f.puts msg
        f.puts ""

        vmc_dir = File.expand_path("../../../..", __FILE__) + "/"
        e.backtrace.each do |loc|
          if loc =~ /\/gems\//
            f.puts loc.sub(/.*\/gems\//, "")
          else
            f.puts loc.sub(vmc_dir, "")
          end
        end
      end
    end

    def quiet?
      input[:quiet]
    end

    def force?
      input[:force]
    end

    def color_enabled?
      input[:color]
    end

    def verbose?
      input[:verbose]
    end

    def user_colors
      return @user_colors if @user_colors

      colors = File.expand_path(COLORS_FILE)

      @user_colors = super.dup

      # most terminal schemes are stupid, so use cyan instead
      @user_colors.each do |k, v|
        if v == :blue
          @user_colors[k] = :cyan
        end
      end

      if File.exists?(colors)
        YAML.load_file(colors).each do |k, v|
          @user_colors[k.to_sym] = v.to_sym
        end
      end

      @user_colors
    end

    def err(msg, status = 1)
      if quiet?
        $stderr.puts(msg)
      else
        puts c(msg, :error)
      end

      exit_status status
    end

    def fail(msg)
      raise UserError, msg
    end

    def table(headers, rows)
      tabular(
        !quiet? && headers.collect { |h| h && b(h) },
        *rows)
    end

    def name_list(xs)
      if xs.empty?
        d("none")
      else
        xs.collect { |x| c(x.name, :name) }.join(", ")
      end
    end

    def sane_target_url(url)
      unless url =~ /^https?:\/\//
        begin
          TCPSocket.new(url, Net::HTTP.https_default_port)
          url = "https://#{url}"
        rescue Errno::ECONNREFUSED, SocketError, Timeout::Error
          url = "http://#{url}"
        end
      end

      url.gsub(/\/$/, "")
    end

    def target_file
      one_of(VMC::TARGET_FILE, VMC::OLD_TARGET_FILE)
    end

    def tokens_file
      one_of(VMC::TOKENS_FILE, VMC::OLD_TOKENS_FILE)
    end

    def one_of(*paths)
      paths.each do |p|
        exp = File.expand_path(p)
        return exp if File.exist? exp
      end

      File.expand_path(paths.first)
    end

    def client_target
      File.read(target_file).chomp
    end

    def ensure_config_dir
      config = File.expand_path(VMC::CONFIG_DIR)
      Dir.mkdir(config) unless File.exist? config
    end

    def set_target(url)
      ensure_config_dir

      File.open(File.expand_path(VMC::TARGET_FILE), "w") do |f|
        f.write(sane_target_url(url))
      end

      invalidate_client
    end

    def targets_info
      new_toks = File.expand_path(VMC::TOKENS_FILE)
      old_toks = File.expand_path(VMC::OLD_TOKENS_FILE)

      if File.exist? new_toks
        YAML.load_file(new_toks)
      elsif File.exist? old_toks
        MultiJson.load(File.read(old_toks))
      else
        {}
      end
    end

    def target_info(target = client_target)
      info = targets_info[target]

      if info.is_a? String
        { :token => info }
      else
        info || {}
      end
    end

    def save_targets(ts)
      ensure_config_dir

      File.open(File.expand_path(VMC::TOKENS_FILE), "w") do |io|
        YAML.dump(ts, io)
      end
    end

    def save_target_info(info, target = client_target)
      ts = targets_info
      ts[target] = info
      save_targets(ts)
    end

    def remove_target_info(target = client_target)
      ts = targets_info
      ts.delete target
      save_targets(ts)
    end

    def no_v2
      fail "Not implemented for v2." if v2?
    end

    def v2?
      client.is_a?(CFoundry::V2::Client)
    end

    def invalidate_client
      @@client = nil
      client
    end

    def client(target = client_target)
      return @@client if defined?(@@client) && @@client

      info = target_info(target)

      @@client =
        case info[:version]
        when 2
          CFoundry::V2::Client.new(target, info[:token])
        when 1
          CFoundry::V1::Client.new(target, info[:token])
        else
          CFoundry::Client.new(target, info[:token])
        end

      @@client.proxy = input[:proxy]
      @@client.trace = input[:trace]

      uri = URI.parse(target)
      @@client.log = File.expand_path("#{LOGS_DIR}/#{uri.host}.log")

      unless info.key? :version
        info[:version] =
          case @@client
          when CFoundry::V2::Client
            2
          else
            1
          end

        save_target_info(info, target)
      end

      if org = info[:organization]
        @@client.current_organization = @@client.organization(org)
      end

      if space = info[:space]
        @@client.current_space = @@client.space(space)
      end

      @@client
    end

    class << self
      def client
        @@client
      end

      def client=(c)
        @@client = c
      end

      private

      def find_by_name(what)
        proc { |name, choices, *_|
          choices.find { |c| c.name == name } ||
            fail("Unknown #{what} '#{name}'.")
        }
      end

      def by_name(what, obj = what)
        proc { |name, *_|
          client.send(:"#{obj}_by_name", name) ||
            fail("Unknown #{what} '#{name}'.")
        }
      end

      def find_by_name_insensitive(what)
        proc { |name, choices|
          choices.find { |c| c.name.upcase == name.upcase } ||
            fail("Unknown #{what} '#{name}'.")
        }
      end
    end
  end
end
