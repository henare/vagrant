require "log4r"

require 'vagrant/provisioners/chef'

module Vagrant
  module Provisioners
    # This class implements provisioning via chef-solo.
    class ChefSolo < Chef
      extend Util::Counter
      include Util::Counter

      class Config < Chef::Config
        attr_accessor :cookbooks_path
        attr_accessor :roles_path
        attr_accessor :data_bags_path
        attr_accessor :recipe_url
        attr_accessor :nfs

        def initialize
          super

          @cookbooks_path = ["cookbooks", [:vm, "cookbooks"]]
          @nfs = false
        end

        def validate(env, errors)
          super

          errors.add(I18n.t("vagrant.config.chef.cookbooks_path_empty")) if !cookbooks_path || [cookbooks_path].flatten.empty?
          errors.add(I18n.t("vagrant.config.chef.run_list_empty")) if !run_list || run_list.empty?
        end
      end

      attr_reader :cookbook_folders
      attr_reader :role_folders
      attr_reader :data_bags_folders

      def self.config_class
        Config
      end

      def initialize(env, config)
        super
        @logger = Log4r::Logger.new("vagrant::provisioners::chef_solo")
      end

      def prepare
        @cookbook_folders = expanded_folders(config.cookbooks_path, "cookbooks")
        @role_folders = expanded_folders(config.roles_path, "roles")
        @data_bags_folders = expanded_folders(config.data_bags_path, "data_bags")

        share_folders("csc", @cookbook_folders)
        share_folders("csr", @role_folders)
        share_folders("csdb", @data_bags_folders)
      end

      def provision!
        # Verify that the proper shared folders exist.
        check = []
        [@cookbook_folders, @role_folders, @data_bags_folders].each do |folders|
          folders.each do |type, local_path, remote_path|
            # We only care about checking folders that have a local path, meaning
            # they were shared from the local machine, rather than assumed to
            # exist on the VM.
            check << remote_path if local_path
          end
        end

        verify_shared_folders(check)

        verify_binary(chef_binary_path("chef-solo"))
        chown_provisioning_folder
        setup_json
        setup_solo_config
        run_chef_solo
      end

      # Converts paths to a list of properly expanded paths with types.
      def expanded_folders(paths, appended_folder=nil)
        return [] if paths.nil?

        # Convert the path to an array if it is a string or just a single
        # path element which contains the folder location (:host or :vm)
        paths = [paths] if paths.is_a?(String) || paths.first.is_a?(Symbol)

        paths.map do |path|
          path = [:host, path] if !path.is_a?(Array)
          type, path = path

          # Create the local/remote path based on whether this is a host
          # or VM path.
          local_path = nil
          local_path = File.expand_path(path, env[:root_path]) if type == :host
          remote_path = nil
          if type == :host
            # Path exists on the host, setup the remote path
            remote_path = "#{config.provisioning_path}/chef-solo-#{get_and_update_counter(:cookbooks_path)}"
          else
            # Path already exists on the virtual machine. Expand it
            # relative to where we're provisioning.
            remote_path = File.expand_path(path, config.provisioning_path)

            # Remove drive letter if running on a windows host. This is a bit
            # of a hack but is the most portable way I can think of at the moment
            # to achieve this. Otherwise, Vagrant attempts to share at some crazy
            # path like /home/vagrant/c:/foo/bar
            remote_path = remote_path.gsub(/^[a-zA-Z]:/, "")
          end

          # If we have specified a folder name to append then append it
          remote_path += "/#{appended_folder}" if appended_folder

          # Return the result
          [type, local_path, remote_path]
        end
      end

      # Shares the given folders with the given prefix. The folders should
      # be of the structure resulting from the `expanded_folders` function.
      def share_folders(prefix, folders)
        folders.each do |type, local_path, remote_path|
          if type == :host
            env[:vm].config.vm.share_folder("v-#{prefix}-#{self.class.get_and_update_counter(:shared_folder)}",
                                       remote_path, local_path, :nfs => config.nfs)
          end
        end
      end

      def setup_solo_config
        cookbooks_path = guest_paths(@cookbook_folders)
        roles_path = guest_paths(@role_folders).first
        data_bags_path = guest_paths(@data_bags_folders).first

        setup_config("provisioners/chef_solo/solo", "solo.rb", {
          :node_name => config.node_name,
          :provisioning_path => config.provisioning_path,
          :cookbooks_path => cookbooks_path,
          :recipe_url => config.recipe_url,
          :roles_path => roles_path,
          :data_bags_path => data_bags_path,
        })
      end

      def run_chef_solo
        command_env = config.binary_env ? "#{config.binary_env} " : ""
        command = "#{command_env}#{chef_binary_path("chef-solo")} -c #{config.provisioning_path}/solo.rb -j #{config.provisioning_path}/dna.json"

        config.attempts.times do |attempt|
          if attempt == 0
            env[:ui].info I18n.t("vagrant.provisioners.chef.running_solo")
          else
            env[:ui].info I18n.t("vagrant.provisioners.chef.running_solo_again")
          end

          exit_status = env[:vm].channel.sudo(command, :error_check => false) do |type, data|
            # Output the data with the proper color based on the stream.
            color = type == :stdout ? :green : :red

            # Note: Be sure to chomp the data to avoid the newlines that the
            # Chef outputs.
            env[:ui].info(data.chomp, :color => color, :prefix => false)
          end

          # There is no need to run Chef again if it converges
          return if exit_status == 0
        end

        # If we reached this point then Chef never converged! Error.
        raise ChefError, :no_convergence
      end

      def verify_shared_folders(folders)
        folders.each do |folder|
          @logger.debug("Checking for shared folder: #{folder}")
          if !env[:vm].channel.test("test -d #{folder}")
            raise ChefError, :missing_shared_folders
          end
        end
      end

      protected

      # Extracts only the remote paths from a list of folders
      def guest_paths(folders)
        folders.map { |parts| parts[2] }
      end
    end
  end
end
