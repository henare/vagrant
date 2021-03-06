require 'vagrant/guest/linux/error'
require 'vagrant/guest/linux/config'

module Vagrant
  module Guest
    class Linux < Base
      def distro_dispatch
        if @vm.channel.test("cat /etc/debian_version")
          return :debian if @vm.channel.test("cat /proc/version | grep 'Debian'")
          return :ubuntu if @vm.channel.test("cat /proc/version | grep 'Ubuntu'")
        end

        return :gentoo if @vm.channel.test("cat /etc/gentoo-release")
        return :redhat if @vm.channel.test("cat /etc/redhat-release")
        return :suse if @vm.channel.test("cat /etc/SuSE-release")
        return :arch if @vm.channel.test("cat /etc/arch-release")

        # Can't detect the distro, assume vanilla linux
        nil
      end

      def halt
        vm.channel.sudo("shutdown -h now")

        # Wait until the VM's state is actually powered off. If this doesn't
        # occur within a reasonable amount of time (15 seconds by default),
        # then simply return and allow Vagrant to kill the machine.
        count = 0
        while vm.state != :poweroff
          count += 1

          return if count >= vm.config.linux.halt_timeout
          sleep vm.config.linux.halt_check_interval
        end
      end

      def mount_shared_folder(name, guestpath, options)
        @vm.channel.sudo("mkdir -p #{guestpath}")
        mount_folder(name, guestpath, options)
        @vm.channel.sudo("chown `id -u #{options[:owner]}`:`id -g #{options[:group]}` #{guestpath}")
      end

      def mount_nfs(ip, folders)
        # TODO: Maybe check for nfs support on the guest, since its often
        # not installed by default
        folders.each do |name, opts|
          vm.channel.sudo("mkdir -p #{opts[:guestpath]}")
          vm.channel.sudo("mount #{ip}:'#{opts[:hostpath]}' #{opts[:guestpath]}",
                          :error_class => LinuxError,
                          :error_key => :mount_nfs_fail)
        end
      end

      #-------------------------------------------------------------------
      # "Private" methods which assist above methods
      #-------------------------------------------------------------------
      def mount_folder(name, guestpath, options)
        # Determine the permission string to attach to the mount command
        mount_options = "-o uid=`id -u #{options[:owner]}`,gid=`id -g #{options[:group]}`"
        mount_options += ",#{options[:extra]}" if options[:extra]

        attempts = 0
        while true
          success = true
          @vm.channel.sudo("mount -t vboxsf #{mount_options} #{name} #{guestpath}") do |type, data|
            success = false if type == :stderr && data =~ /No such device/i
          end

          break if success

          attempts += 1
          raise LinuxError, :mount_fail if attempts >= 10
          sleep 5
        end
      end
    end
  end
end
