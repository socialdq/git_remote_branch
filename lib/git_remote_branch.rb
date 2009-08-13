require 'rubygems'

if RUBY_VERSION =~ /1\.8/
  gem 'colored', '>= 1.1'
  require 'colored'
else
  class String
    def red; self; end
  end
end

begin
  WINDOWS = !!(RUBY_PLATFORM =~ /win32|cygwin/)
rescue Exception
end

grb_app_root = File.expand_path( File.dirname(__FILE__) + '/..' )

$LOAD_PATH.unshift( grb_app_root + '/vendor' )
require 'capture_fu'

$LOAD_PATH.unshift( grb_app_root + '/lib' )
%w(monkey_patches constants  state param_reader version).each do |f|
  require f
end

module GitRemoteBranch
  class InvalidBranchError < RuntimeError; end
  class NotOnGitRepositoryError < RuntimeError; end

  COMMANDS = {
    :create     => {
      :description => 'create a new remote branch and track it locally',
      :aliases  => %w{create new},
      :commands => [
        '"#{GIT} push #{origin} #{current_branch}:refs/heads/#{branch_name}"',
        '"#{GIT} fetch #{origin}"',
        '"#{GIT} branch --track #{branch_name} #{origin}/#{branch_name}"',
        '"#{GIT} checkout #{branch_name}"'
      ]
    },

    :publish     => {
      :description => 'publish an exiting local branch',
      :aliases  => %w{publish remotize share},
      :commands => [
        '"#{GIT} push #{origin} #{branch_name}:refs/heads/#{branch_name}"',
        '"#{GIT} fetch #{origin}"',
        '"#{GIT} config branch.#{branch_name}.remote #{origin}"',
        '"#{GIT} config branch.#{branch_name}.merge refs/heads/#{branch_name}"',
        '"#{GIT} checkout #{branch_name}"'
      ]
    },

    :rename     => {
      :description => 'rename a remote branch and its local tracking branch',
      :aliases  => %w{rename rn mv move},
      :commands => [
        '"#{GIT} push #{origin} #{current_branch}:refs/heads/#{branch_name}"',
        '"#{GIT} fetch #{origin}"',
        '"#{GIT} branch --track #{branch_name} #{origin}/#{branch_name}"',
        '"#{GIT} checkout #{branch_name}"',
        '"#{GIT} push #{origin} :refs/heads/#{current_branch}"',
        '"#{GIT} branch -d #{current_branch}"',
      ]
    },

    :delete     => {
      :description => 'delete a local and a remote branch',
      :aliases  => %w{delete destroy kill remove rm},
      :commands => [
        '"#{GIT} push #{origin} :refs/heads/#{branch_name}"',
        '"#{GIT} checkout master" if current_branch == branch_name',
        '"#{GIT} branch -d #{branch_name}"'
      ]
    },
    
    :retrack    => {
      :description => 'delete and then track a remote branch',
      :aliases  => %w{retrack},
      :commands => [
        '"#{GIT} checkout master"',
        '"#{GIT} branch -D #{branch_name}"',
        '"#{GIT} fetch #{origin}"',
        '"#{GIT} branch --track #{branch_name} #{origin}/#{branch_name}"',
        '"#{GIT} checkout #{branch_name}"'
      ]
    },

    :track      => {
      :description => 'track an existing remote branch',
      :aliases  => %w{track follow grab fetch},
      :commands => [
        # This string programming thing is getting old. Not flexible enough anymore.
        '"#{GIT} fetch #{origin}"',
        'if local_branches.include?(branch_name) 
          "#{GIT} config branch.#{branch_name}.remote #{origin}\n" +
          "#{GIT} config branch.#{branch_name}.merge refs/heads/#{branch_name}"
        else
          "#{GIT} branch --track #{branch_name} #{origin}/#{branch_name}"
        end',
        '"#{GIT} checkout #{branch_name}"'
      ]
    },

    :unfork      => {
      :description => 'unfork a remote (e.g. github) branch',
      :aliases  => %w{unfork},
    }
  } unless defined?(COMMANDS)

  def track_steps(p)
    branch_name, origin = p[:branch], p[:origin]
    res = ["#{GIT} fetch #{origin}"]
    if local_branches.include?(branch_name) 
      res << "#{GIT} config branch.#{branch_name}.remote #{origin}"
      res << "#{GIT} config branch.#{branch_name}.merge refs/heads/#{branch_name}"
    else
      res << "#{GIT} branch --track #{branch_name} #{origin}/#{branch_name}"
    end
    res
  end

  def unfork_steps(p)
    branch_name, origin, current_branch = p[:branch], p[:origin], p[:current_branch]
    res = track_steps :branch => current_branch, :origin => branch_name # branch_name is the remote branch name/reference
    res << "git push -f #{origin} #{current_branch}:refs/heads/#{current_branch}" 
    res + track_steps(:branch => current_branch, :origin => origin)
  end
  
  def self.get_reverse_map(commands)
    h={}
    commands.each_pair do |cmd, params|
      params[:aliases].each do |alias_|
        unless h[alias_]
          h[alias_] = cmd
        else
          raise "Duplicate aliases: #{alias_.inspect} already defined for command #{h[alias_].inspect}"
        end
      end
    end
    h
  end
  ALIAS_REVERSE_MAP = get_reverse_map(COMMANDS) unless defined?(ALIAS_REVERSE_MAP)
  
  def get_welcome
    "git_remote_branch version #{VERSION::STRING}\n\n"
  end

  def get_usage
    return <<-HELP
  Usage:

#{[:create, :publish, :rename, :delete, :track, :retrack].map{|action|
      "  grb #{action} branch_name [origin_server] \n\n"
    }  
  }
  grb unfork remote_branch_ref [origin_server]
  
  Notes:
  - If origin_server is not specified, the name 'origin' is assumed (git's default)
  - The rename functionality renames the current branch
  - The unfork command operates on current branch - enforces the current
    branch (e.g. master) to follow the remote repository (again)
  
  The explain meta-command: you can also prepend any command with the keyword 'explain'. Instead of executing the command, git_remote_branch will simply output the list of commands you need to run to accomplish that goal.
  Example: 
    grb explain create
    grb explain create my_branch github
  
  Commands also have aliases:
  #{ COMMANDS.keys.map{|k| k.to_s}.sort.map {|cmd| 
    "#{cmd}: #{COMMANDS[cmd.to_sym][:aliases].join(', ')}" }.join("\n  ") }
  HELP
  end

  # New approach: define a function per action e.g. track_steps, unfork_steps 
  # that accepts hash with invocation parameters,
  # invoke through metaprogramming `send "#{action}_steps"`
  def compute_steps(p)
    action, branch_name, origin, current_branch = p[:action], p[:branch], p[:origin], p[:current_branch]
    if COMMANDS[action][:commands]
      COMMANDS[action][:commands].map{ |c| eval(c) }.compact # old way
    else
      self.send "#{action}_steps", p # new way
    end
  end

  def execute_action(params)
    execute_cmds compute_steps(params)
  end

  def explain_action(params)
    whisper "List of operations to do to #{COMMANDS[params[:action]][:description]}:", ''
    puts_cmd compute_steps(params)
    whisper ''
  end

  def execute_cmds(*cmds)
    silencer = $WHISPER ? ' 2>&1' : ''
    cmds.flatten.each do |c|
      puts_cmd c
      `#{c}#{silencer}`
      whisper ''
    end
  end

  def puts_cmd(*cmds)
    cmds.flatten.each do |c|
      whisper "#{c}".red
    end
  end
end
