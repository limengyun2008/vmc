require "vmc/cli"

module VMC
  class Start < CLI
    desc "Display information on the current target, user, etc."
    group :start
    input :runtimes, :type => :boolean,
      :desc => "List supported runtimes"
    input :services, :type => :boolean,
      :desc => "List supported services"
    input :frameworks, :type => :boolean,
      :desc => "List supported frameworks"
    input(:all, :type => :boolean, :alias => "-a",
          :desc => "Show all information")
    def info(input)
      all = input[:all]

      if all || input[:runtimes]
        runtimes =
          with_progress("Getting runtimes") do
            client.runtimes
          end
      end

      if all || input[:services]
        services =
          with_progress("Getting services") do
            client.services
          end
      end

      if all || input[:frameworks]
        frameworks =
          with_progress("Getting frameworks") do
            client.frameworks
          end
      end

      info = client.info

      showing_any = runtimes || services || frameworks

      unless !all && showing_any
        puts "" if showing_any
        puts info[:description]
        puts ""
        puts "target: #{b(client.target)}"
        puts "  version: #{info[:version]}"
        puts "  support: #{info[:support]}"

        if user = client.current_user
          puts ""
          puts "user: #{b(user.email || user.id)}"
        end
      end

      if runtimes
        unless quiet?
          puts ""
          puts "runtimes:"
        end

        puts "  #{c("none", :dim)}" if runtimes.empty? && !quiet?

        runtimes.each.with_index do |r, i|
          display_runtime(r)
          puts "" unless quiet? || i + 1 == runtimes.size
        end
      end

      if services
        unless quiet?
          puts ""
          puts "services:"
        end

        puts "  #{c("none", :dim)}" if services.empty? && !quiet?

        services.each.with_index do |s, i|
          display_service(s)
          puts "" unless quiet? || i + 1 == services.size
        end
      end

      if frameworks
        unless quiet?
          puts ""
          puts "frameworks:"
        end

        puts "  #{c("none", :dim)}" if frameworks.empty? && !quiet?

        frameworks.each.with_index do |f, i|
          display_framework(f)
          puts "" unless quiet? || i + 1 == frameworks.size
        end
      end
    end


    desc "Set or display the current target cloud"
    group :start
    input :url, :argument => :optional,
      :desc => "Target URL to switch to"
    input(:organization, :aliases => ["--org", "-o"],
          :desc => "Organization") { |choices|
      ask("Organization", :choices => choices)
    }
    input(:space, :alias => "-s", :desc => "Space") { |choices|
      ask("Space", :choices => choices)
    }
    def target(input)
      if !input.given?(:url) && !input.given?(:organization) &&
          !input.given?(:space)
        display_target

        if v2? && client.current_organization && client.current_space
          puts "Organization: #{c(client.current_organization.name, :name)}"
          puts "Space: #{c(client.current_space.name, :name)}"
        end

        return
      end

      if input.given?(:url)
        target = sane_target_url(input[:url])
        display = c(target.sub(/https?:\/\//, ""), :name)
        with_progress("Setting target to #{display}") do
          set_target(target)
        end

        return if force?
      end

      return unless v2?

      unless client.logged_in?
        invoke :login
        @client = nil
      end

      info = target_info

      select_org_and_space(input, info)

      save_target_info(info)
    end


    desc "List known targets."
    group :start, :hidden => true
    def targets(input)
      targets.each do |target, _|
        puts target
        # TODO: print org/space
      end
    end


    def ask_prompt(type, label)
      if type == "password"
        options = { :echo => "*", :forget => true }
      else
        options = {}
      end

      ask(label, options)
    end

    def ask_prompts(credentials, prompts)
      prompts.each do |name, meta|
        type, label = meta
        credentials[name] ||= ask_prompt(type, label)
      end
    end

    desc "Authenticate with the target"
    group :start
    input :username, :alias => "--email", :argument => :optional,
      :desc => "Account email"
    input :password, :desc => "Account password"
    input(:organization, :aliases => ["--org", "-o"],
          :desc => "Organization") { |choices|
      ask("Organization", :choices => choices)
    }
    input(:space, :alias => "-s", :desc => "Space") { |choices|
      ask("Space", :choices => choices)
    }
    def login(input)
      unless quiet?
        display_target
        puts ""
      end

      credentials =
        { :username => input[:username],
          :password => input[:password]
        }

      prompts = client.login_prompts

      # ask username first
      if prompts.key? :username
        type, label = prompts.delete :username
        credentials[:username] ||= ask_prompt(type, label)
      end

      info = target_info

      authenticated = false
      failed = false
      until authenticated
        unless force?
          ask_prompts(credentials, prompts)
        end

        with_progress("Authenticating") do |s|
          begin
            info[:token] = client.login(credentials)
            authenticated = true
          rescue CFoundry::Denied
            return if force?

            s.fail do
              failed = true
              credentials.delete(:password)
            end
          end
        end
      end

      select_org_and_space(input, info) if v2?

      save_target_info(info)
    ensure
      exit_status 1 if not authenticated
    end


    desc "Log out from the target"
    group :start
    def logout(input)
      with_progress("Logging out") do
        remove_target_info
      end
    end


    desc "Create a user and log in"
    group :start, :hidden => true
    input(:email, :argument => true, :desc => "Desired email") {
      ask("Email")
    }
    input(:password, :desc => "Desired password") {
      ask("Password", :echo => "*", :forget => true)
    }
    input(:verify, :desc => "Repeat password") {
      ask("Confirm Password", :echo => "*", :forget => true)
    }
    input :login, :type => :boolean, :default => true,
      :desc => "Automatically log in?"
    def register(input)
      unless quiet?
        puts "Target: #{c(client_target, :name)}"
        puts ""
      end

      email = input[:email]
      password = input[:password]

      if !force? && password != input[:verify]
        fail "Passwords do not match."
      end

      with_progress("Creating user") do
        client.register(email, password)
      end

      if input[:login]
        with_progress("Logging in") do
          save_token(client.login(email, password))
        end
      end
    end


    desc "Show color configuration"
    group :start, :hidden => true
    def colors(input)
      user_colors.each do |n, c|
        puts "#{n}: #{c(c.to_s, n)}"
      end
    end

    private

    def display_target
      if quiet?
        puts client.target
      else
        puts "Target: #{c(client.target, :name)}"
      end
    end

    def display_runtime(r)
      if quiet?
        puts r.name
      else
        puts "  #{c(r.name, :name)}:"

        puts "    description: #{b(r.description)}" if r.description

        # TODO: probably won't have this in final version
        apps = r.apps.collect { |a| c(a.name, :name) }
        app_list = apps.empty? ? c("none", :dim) : apps.join(", ")
        puts "    apps: #{app_list}"
      end
    end

    def display_service(s)
      if quiet?
        puts s.label
      else
        puts "  #{c(s.label, :name)}:"
        puts "    description: #{s.description}"
        puts "    version: #{s.version}"
        puts "    provider: #{s.provider}"
      end
    end

    def display_framework(f)
      if quiet?
        puts f.name
      else
        puts "  #{c(f.name, :name)}:"
        puts "    description: #{b(f.description)}" if f.description

        # TODO: probably won't show this in final version; just for show
        apps = f.apps.collect { |a| c(a.name, :name) }
        puts "    apps: #{apps.empty? ? c("none", :dim) : apps.join(", ")}"
      end
    end

    def org_valid?(id, user = client.current_user)
      return false unless id
      client.organization(id).users.include? user
    rescue CFoundry::APIError
      false
    end

    def space_valid?(id, user = client.current_user)
      return false unless id
      client.space(id).developers.include? user
    rescue CFoundry::APIError
      false
    end

    def select_org_and_space(input, info)
      if input.given?(:organization) || !org_valid?(info[:organization])
        orgs = client.organizations
        fail "No organizations!" if orgs.empty?

        if orgs.size == 1 && !input.given?(:organization)
          org = orgs.first
        else
          org_name = input[:organization, orgs.collect(&:name).sort]
          org = orgs.find { |o| o.name == org_name }
          fail "Unknown organization '#{org_name}'" unless org
        end

        info[:organization] = org.id
      else
        org = client.current_organization
      end

      # switching org probably means switching space
      if input.given?(:organization) || input.given?(:space) || \
            !space_valid?(info[:space])
        spaces = client.spaces.select do |s|
          s.organization.id == org.id
        end

        fail "No spaces!" if spaces.empty?

        if spaces.size == 1 && !input.given?(:space)
          space = spaces.first
        else
          space_name = input[:space, spaces.collect(&:name).sort]
          space = spaces.find { |s| s.name == space_name }
          fail "Unknown space '#{space_name}'" unless space
        end

        info[:space] = space.id
      end
    end
  end
end