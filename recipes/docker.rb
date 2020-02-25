# Install and start Docker

case node['platform_family']
when 'rhel'
  package 'docker'
when 'debian'
  package 'docker.io'
end

if node['hops']['gpu'].eql?("true")
  package_type = node['platform_family'].eql?("debian") ? "_amd64.deb" : ".x86_64.rpm"
  case node['platform_family']
  when 'rhel'
    nvidia_docker_packages = ["libnvidia-container1-1.0.5-1#{package_type}", "libnvidia-container-tools-1.0.5-1#{package_type}", "nvidia-container-toolkit-1.0.5-2#{package_type}", "nvidia-container-runtime-2.0.0-1.docker1.13.1#{package_type}"]
  when 'debian'
    nvidia_docker_packages = ["libnvidia-container1-1.0.7-1#{package_type}", "libnvidia-container-tools-1.0.7-1#{package_type}", "nvidia-container-toolkit-1.0.5-1#{package_type}", "nvidia-container-runtime_3.1.4-1#{package_type}"]
  end
  nvidia_docker_packages.each do |pkg|
    remote_file "#{Chef::Config['file_cache_path']}/#{pkg}" do
      source "#{node['download_url']}/kube/nvidia/#{pkg}"
      owner 'root'
      group 'root'
      mode '0755'
      action :create
    end
  end

  # Install packages & Platform specific configuration
  case node['platform_family']
  when 'rhel'

    bash "install_pkgs" do
      user 'root'
      group 'root'
      cwd Chef::Config['file_cache_path']
      code <<-EOH
        yum install -y #{nvidia_docker_packages.join(" ")}
        EOH
      not_if "yum list installed libnvidia-container1"
    end

    # Disabling SELinux by running setenforce 0 is required to allow containers to access
    # the host filesystem, which is required by pod networks for example.
    # You have to do this until SELinux support is improved in the kubelet.
    bash 'disable_selinux' do
      user 'root'
      group 'root'
      code <<-EOH
        setenforce 0
        sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
        EOH
    end

  when 'debian'

    bash "install_pkgs" do
      user 'root'
      group 'root'
      cwd Chef::Config['file_cache_path']
      code <<-EOH
        apt-get install -y #{nvidia_docker_packages.join(" ")}
        EOH
    end
  end

end

if !node['hops']['docker_dir'].eql?("/var/lib/docker")
  directory node['hops']['docker_dir'] do
    owner 'root'
    group 'root'
    mode '0711'
    recursive true
    action :create
  end
end

# Configure Docker
# On CENTOS docker comes down already with a basic configuration which might conflict with the 
# daemon.json configuration we template here. So we replace the configuration file
storage_opts = ""
if node['platform_family'].eql?("rhel")
  storage_opts = "overlay2.override_kernel_check=true"
 
  template '/lib/systemd/system/docker.service' do
    source 'docker.service.erb'
    owner 'root'
    mode '0755'
    action :create
  end

  template '/etc/sysconfig/docker' do
    source 'docker.erb'
    owner 'root'
    mode '0755'
    action :create
  end
end

template '/etc/docker/daemon.json' do
  source 'daemon.json.erb'
  owner 'root'
  mode '0755'
  variables ({
    'storage_opts': storage_opts
  })
  action :create
end

# Start the docker deamon
service 'docker' do
  action [:enable, :start]
end

#download base env
image_url = node['hops']['docker']['base_env']['download_url']
base_filename = File.basename(image_url)

remote_file "/tmp/#{base_filename}" do
  source image_url
  backup false
  action :create_if_missing
  not_if 'docker image inspect local/python36'
end

#import docker image
bash "import_image" do
  user "root"
  code <<-EOF
    docker load -i /tmp/#{base_filename}
  EOF
  not_if 'docker image inspect local/python36'
end

#delete tar
file "/tmp/#{base_filename}" do
  action :delete
  only_if { File.exist? "/tmp/#{base_filename}" }
end
