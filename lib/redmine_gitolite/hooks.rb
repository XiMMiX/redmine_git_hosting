module RedmineGitolite

  class Hooks

    def self.check_hooks_installed
      check_hook_file_installed("post-receive.redmine_gitolite.rb") && check_hook_dir_installed && check_hook_file_installed("post-receive.mail_notifications.sh")
    end


    @@check_hooks_installed_stamp = {}
    @@check_hooks_installed_cached = {}
    @@post_receive_hook_path = {}

    def self.check_hook_file_installed(hook_file)
      hook_name = hook_file.split('.')[1].to_sym
      logger.info "Installing hook '#{hook_name}' => '#{hook_file}'"

      if not @@check_hooks_installed_cached[hook_name].nil? and (Time.new - @@check_hooks_installed_stamp[hook_name] <= 1)
        return @@check_hooks_installed_cached[hook_name]
      end

      gitolite_command = get_gitolite_command

      if gitolite_command.nil?
        logger.error "Unable to find Gitolite version, cannot install '#{hook_file}' hook file !"
        @@check_hooks_installed_stamp[hook_name] = Time.new
        @@check_hooks_installed_cached[hook_name] = false
        return @@check_hooks_installed_cached[hook_name]
      end

      if hook_name == :redmine_gitolite
        @@post_receive_hook_path[hook_name] ||= File.join(gitolite_hooks_dir, 'post-receive')
      else
        @@post_receive_hook_path[hook_name] ||= File.join(gitolite_hooks_dir, 'post-receive.d', "#{hook_name}")
      end

      logger.info "Hook destination path : '#{@@post_receive_hook_path[hook_name]}'"

      post_receive_exists = (%x[#{GitHosting.shell_cmd_runner} test -r '#{@@post_receive_hook_path[hook_name]}' && echo 'yes' || echo 'no']).match(/yes/)
      post_receive_length_is_zero = false
      if post_receive_exists
        post_receive_length_is_zero= "0" == (%x[echo 'wc -c #{@@post_receive_hook_path[hook_name]}' | #{GitHosting.shell_cmd_runner} "bash" ]).chomp.strip.split(/[\t ]+/)[0]
      end

      if (!post_receive_exists) || post_receive_length_is_zero

        begin
          logger.info "Hook '#{hook_name}' not handled by us, installing it..."
          install_hook_file(hook_file, @@post_receive_hook_path[hook_name])
          logger.info "Hook '#{hook_file}' installed"

          logger.info "Running '#{gitolite_command}' on the Gitolite install..."
          GitHosting.shell %[#{GitHosting.shell_cmd_runner} #{gitolite_command}]

          update_global_hook_params

          @@check_hooks_installed_cached[hook_name] = true
        rescue => e
          logger.error "check_hooks_installed(): Problems installing hooks '#{hook_name}' and initializing Gitolite!"
          logger.error e.message
          @@check_hooks_installed_cached[hook_name] = false
        end

        @@check_hooks_installed_stamp[hook_name] = Time.new
        return @@check_hooks_installed_cached[hook_name]

      else

        contents = %x[#{GitHosting.shell_cmd_runner} 'cat #{@@post_receive_hook_path[hook_name]}']
        digest = Digest::MD5.hexdigest(contents)

        if current_hook_digest(hook_name, hook_file) == digest
          logger.info "Our '#{hook_name}' hook is already installed"
          @@check_hooks_installed_stamp[hook_name] = Time.new
          @@check_hooks_installed_cached[hook_name] = true
          return @@check_hooks_installed_cached[hook_name]
        else
          error_msg = "Hook '#{hook_name}' is already present but it's not ours!"
          logger.warn error_msg
          @@check_hooks_installed_cached[hook_name] = error_msg

          if RedmineGitolite::Config.gitolite_force_hooks_update?
            begin
              logger.info "Restoring '#{hook_name}' hook since forceInstallHook == true"
              install_hook_file(hook_file, @@post_receive_hook_path[hook_name])
              logger.info "Hook '#{hook_file}' installed"

              logger.info "Running '#{gitolite_command}' on the Gitolite install..."
              GitHosting.shell %[#{GitHosting.shell_cmd_runner} #{gitolite_command}]

              update_global_hook_params

              @@check_hooks_installed_cached[hook_name] = true
            rescue => e
              logger.error "check_hooks_installed(): Problems installing hooks '#{hook_name}' and initializing Gitolite!"
              logger.error e.message
              @@check_hooks_installed_cached[hook_name] = false
            end
          end

          @@check_hooks_installed_stamp[hook_name] = Time.new
          return @@check_hooks_installed_cached[hook_name]
        end

      end
    end


    @@check_hooks_dir_installed_cached = nil
    @@check_hooks_dir_installed_stamp = nil

    def self.check_hook_dir_installed
      if not @@check_hooks_dir_installed_cached.nil? and (Time.new - @@check_hooks_dir_installed_stamp <= 1)
        return @@check_hooks_dir_installed_cached
      end

      @@post_receive_hook_dir_path ||= File.join(gitolite_hooks_dir, 'post-receive.d')
      post_receive_dir_exists = (%x[#{GitHosting.shell_cmd_runner} test -r '#{@@post_receive_hook_dir_path}' && echo 'yes' || echo 'no']).match(/yes/)

      if (!post_receive_dir_exists)
        begin
          logger.info "Global directory 'post-receive.d' not created yet, installing it..."
          install_hook_dir("post-receive.d")
          logger.info "Global directory 'post-receive.d' installed"

          @@check_hooks_dir_installed_cached = true
        rescue => e
          logger.error "check_hook_dir_installed(): Problems installing hook dir !"
          logger.error e.message
          @@check_hooks_dir_installed_cached = false
        end

        @@check_hooks_dir_installed_stamp = Time.new
        return @@check_hooks_dir_installed_cached
      else
        logger.info "Global directory 'post-receive.d' is already present, will not touch it !"
        @@check_hooks_dir_installed_cached = true
        @@check_hooks_dir_installed_stamp = Time.new
        return @@check_hooks_dir_installed_cached
      end
    end


    @@hook_url = nil
    def self.update_global_hook_params
      cur_values = get_global_config_params

      begin
        @@hook_url ||= "http://" + File.join(RedmineGitolite::Config.my_root_url, "/githooks/post-receive")

        if cur_values["hooks.redmine_gitolite.url"] != @@hook_url
          logger.info "Updating Hook URL: #{@@hook_url}"
          GitHosting.shell %[#{GitHosting.git_cmd_runner} config --global hooks.redmine_gitolite.url "#{@@hook_url}"]
        end

        debug_hook = RedmineGitolite::Config.gitolite_hooks_debug?
        if cur_values["hooks.redmine_gitolite.debug"] != debug_hook.to_s
          logger.info "Updating Debug Hook: #{debug_hook}"
          GitHosting.shell %[#{GitHosting.git_cmd_runner} config --global --bool hooks.redmine_gitolite.debug "#{debug_hook}"]
        end

        asynch_hook = RedmineGitolite::Config.gitolite_hooks_are_asynchronous?
        if cur_values["hooks.redmine_gitolite.asynch"] != asynch_hook.to_s
          logger.info "Updating Hooks Are Asynchronous: #{asynch_hook}"
          GitHosting.shell %[#{GitHosting.git_cmd_runner} config --global --bool hooks.redmine_gitolite.asynch "#{asynch_hook}"]
        end

      rescue => e
        logger.error "update_global_hook_params(): Problems updating hook parameters!"
        logger.error e.message
      end
    end


    private


    def self.logger
      return GitHosting.logger
    end


    def self.get_gitolite_command
      gitolite_version = GitHosting.gitolite_version
      if gitolite_version == 2
        gitolite_command = 'gl-setup'
      elsif gitolite_version == 3
        gitolite_command = 'gitolite setup'
      else
        gitolite_command = nil
      end
      return gitolite_command
    end


    def self.gitolite_hooks_dir
      return '~/.gitolite/hooks/common'
    end


    @@cached_hooks_dir = nil
    def self.package_hooks_dir
      @@cached_hooks_dir ||= File.join(File.dirname(File.dirname(File.dirname(__FILE__))), 'contrib', 'hooks')
    end


    @@cached_hook_digest = {}
    def self.current_hook_digest(hook_name, hook_file, recreate = false)
      if @@cached_hook_digest[hook_name].nil? || recreate
        logger.debug "Creating MD5 digests for '#{hook_name}' hook"
        digest = Digest::MD5.hexdigest(File.read(File.join(package_hooks_dir, hook_file)))
        logger.debug "Digest for '#{hook_name}' hook : #{digest}"
        @@cached_hook_digest[hook_name] = digest
      end
      @@cached_hook_digest[hook_name]
    end


    def self.install_hook_file(hook_file, hook_dest_path)
      begin
        hook_source_path = File.join(package_hooks_dir, hook_file)
        logger.info "Installing '#{hook_file}' in '#{hook_dest_path}'"
        GitHosting.shell %[ cat #{hook_source_path} | #{GitHosting.shell_cmd_runner} 'cat - > #{hook_dest_path}']
        GitHosting.shell %[#{GitHosting.shell_cmd_runner} 'chown #{RedmineGitolite::Config.gitolite_user}.#{RedmineGitolite::Config.gitolite_user} #{hook_dest_path}']
        GitHosting.shell %[#{GitHosting.shell_cmd_runner} 'chmod 700 #{hook_dest_path}']
      rescue => e
        logger.error "install_hook(): Problems installing hook from #{hook_source_path} to #{hook_dest_path}."
        logger.error e.message
      end
    end


    def self.install_hook_dir(hooks_dir)
      begin
        dest_dir = File.join(gitolite_hooks_dir, hooks_dir)
        logger.info "Installing hook directory '#{hooks_dir}' to '#{dest_dir}'"
        GitHosting.shell %[#{GitHosting.shell_cmd_runner} 'mkdir -p #{dest_dir}']
        GitHosting.shell %[#{GitHosting.shell_cmd_runner} 'chown -R #{RedmineGitolite::Config.gitolite_user}.#{RedmineGitolite::Config.gitolite_user} #{dest_dir}']
        GitHosting.shell %[#{GitHosting.shell_cmd_runner} 'chmod 700 #{dest_dir}']
      rescue => e
        logger.error "install_hooks_dir(): Problems installing hook directory to #{dest_dir}"
        logger.error e.message
      end
    end


    # Return a hash with global config parameters.
    def self.get_global_config_params
      begin
        value_hash = {}
        GitHosting.shell %x[#{GitHosting.git_cmd_runner} config -f '.gitconfig' --get-regexp hooks.redmine_gitolite].split("\n").each do |valuepair|
          pair = valuepair.split(' ')
          value_hash[pair[0]] = pair[1]
        end
        value_hash
      rescue => e
        logger.error "get_global_config_params(): Problems to retrieve Gitolite hook parameters in Gitolite config"
        logger.error e.message
      end
    end

  end
end