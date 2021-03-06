require "vmc/cli"

module VMC
  class User < CLI
    desc "List all users"
    group :admin, :hidden => true
    def users
      users =
        with_progress("Getting users") do
          client.users(:depth => 0)
        end

      spaced(users) do |u|
        display_user(u)
      end
    end


    desc "Create a user"
    group :admin, :user, :hidden => true
    input(:email, :argument => true, :desc => "User email") {
      ask("Email")
    }
    input(:password, :desc => "User password") {
      ask("Password", :echo => "*", :forget => true)
    }
    input(:verify, :desc => "Repeat password") {
      ask("Verify Password", :echo => "*", :forget => true)
    }
    def create_user
      email = input[:email]
      password = input[:password]

      if !force? && password != input[:verify]
        fail "Passwords don't match."
      end

      with_progress("Creating user") do
        client.register(email, password)
      end
    end

    alias_command :create_user, :add_user


    desc "Delete a user"
    group :admin, :user, :hidden => true
    input :email, :argument => true, :desc => "User to delete"
    input(:really, :type => :boolean, :forget => true,
          :default => proc { force? || interact }) { |email|
      ask("Really delete user #{c(email, :name)}?", :default => false)
    }
    def delete_user
      email = input[:email]
      return unless input[:really, email]

      with_progress("Deleting #{c(email, :name)}") do
        client.user(email).delete!
      end
    end


    desc "Update a user's password"
    group :admin, :user, :hidden => true
    input :user, :argument => :optional,
      :from_given => proc { |email|
        if v2? && client.current_user.email != email
          fail "You can only change your own password on V2."
        else
          client.user(email)
        end
      },
      :desc => "User to update",
      :default => proc { client.current_user }
    input(:password, :desc => "New password") {
      ask("Current Password", :echo => "*", :forget => true)
    }
    input(:new_password, :desc => "New password") {
      ask("New Password", :echo => "*", :forget => true)
    }
    input(:verify, :desc => "Repeat new password") {
      ask("Verify Password", :echo => "*", :forget => true)
    }
    def passwd
      user = input[:user]
      password = input[:password] if v2?
      new_password = input[:new_password]
      verify = input[:verify]

      if new_password != verify
        fail "Passwords don't match."
      end

      with_progress("Changing password") do
        if v2?
          user.change_password!(new_password, password)
        else
          user.password = new_password
          user.update!
        end
      end
    end

    private

    def display_user(u)
      if quiet?
        puts u.email
      else
        line "#{c(u.email, :name)}:"

        indented do
          line "admin?: #{c(u.admin?, u.admin? ? :yes : :no)}"
        end
      end
    end
  end
end
