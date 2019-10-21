require 'active_model'
require 'nokogiri'
require 'tempfile'
require 'fileutils'
require 'open3'

class ObsPullRequestPackage
  include ActiveModel::Model
  attr_accessor :pull_request, :logger, :template_directory, :config
  PullRequest = Struct.new(:number)
  
  def self.all(logger, config)
    result = `osc api "search/project?match=starts-with(@name,'#{config[:obs][:project]}:PR')"`
    xml = Nokogiri::XML(result)
    xml.xpath('//project').map do |project|
      pull_request_number = project.attribute('name').to_s.split('-').last.to_i
      ObsPullRequestPackage.new(pull_request: PullRequest.new(pull_request_number), logger: logger)
    end
  end

  def delete
    capture2e_with_logs("osc api -X DELETE source/#{obs_project_name}")
  end

  def ==(other)
    pull_request.number == other.pull_request.number
  end

  def eql?(other)
    pull_request.number.eql(other.pull_request.number)
  end

  def hash
    pull_request.number.hash
  end

  def pull_request_number
    pull_request.number
  end
  
  def commit_sha
    pull_request.head.sha
  end
  
  def merge_sha
    # github test merge commit
    pull_request.merge_commit_sha
  end
 
  def obs_pr_project_prefix
    "#{config[:obs][:project]}:PR"
  end

  def obs_project_name
    "#{obs_pr_project_prefix}-#{pull_request_number}"
  end
  
  def url
    "https://build.opensuse.org/project/show/#{obs_project_name}"
  end
  
  def last_commited_sha
    result = capture2e_with_logs("osc api /source/#{obs_project_name}/_meta")
    node = Nokogiri::XML(result).root
    return '' unless node
    node.xpath('.//description').first.content
  end

  def create
    if last_commited_sha == commit_sha
      logger.info('Pull request did not change, skipping ...')
      return
    end
    create_project
    create_packages
    copy_files
  end
  
  private
  
  def capture2e_with_logs(cmd)
    logger.info("Execute command '#{cmd}'.")
    stdout_str, stderr_str, status = Open3.capture3(cmd)
    stdout_str.chomp!
    stderr_str.chomp!
    if status.success?
      logger.info(stdout_str)
    else
      logger.info(stdout_str)
      logger.error(stderr_str)
    end
    stdout_str
  end
  
  def create_project
    Tempfile.open("#{pull_request_number}-meta") do |f|
      f.write(project_meta)
      f.close
      capture2e_with_logs("osc meta prj #{obs_project_name} --file #{f.path}")
    end
  end
  
  def project_meta
    file = File.read('config/new_project_template.xml')
    xml = Nokogiri::XML(file)
    xml.root['name'] = obs_project_name
    xml.xpath('//title').first.content = "https://github.com/openSUSE/open-build-service/pull/#{pull_request_number}"
    xml.xpath('//description').first.content = commit_sha
    xml.to_s
  end
  
  def create_packages
    blacklist = config[:obs][:blacklist_packages]
    whitelist = config[:obs][:only_packages]
    result = capture2e_with_logs("osc api /source/#{config[:obs][:head_project]}")
    xml = Nokogiri::XML(result)
    xml.xpath('//entry').each do |entry|
      package = entry.attribute('name')
      if blacklist and blacklist.include? package
        logger.debug("Omitting blacklisted package #{package}")
        next
      end
      if whitelist and ! whitelist.include? package
        logger.debug("Whilelist specified and package #{package} not included, omitting")
        next
      end
      Tempfile.open("#{package}-meta") do |f|
        f.write(package_meta(package))
        f.close
        capture2e_with_logs("osc meta pkg #{obs_project_name} #{package} --file #{f.path}")
      end
    end
  end

  def package_meta(package)
    result = capture2e_with_logs("osc meta pkg #{config[:obs][:head_project]} #{package}")
    xml = Nokogiri::XML(result)
    node = xml.root['project'] = obs_project_name
    xml.to_s
  end

  def copy_files
    Dir.mktmpdir do |dir|
      capture2e_with_logs("osc co #{config[:obs][:head_project]} --output-dir #{dir}/template")
      capture2e_with_logs("osc co #{obs_project_name} --output-dir #{dir}/#{obs_project_name}")
      Dir.entries("#{dir}/#{obs_project_name}").reject { |name| name.start_with?('.') or File.file?(name) }.each do |package_dir|
        source_dir = File.join(dir, 'template', package_dir)
        target_dir = File.join(dir, obs_project_name, package_dir)
        Dir.exists?(target_dir) or Dir.mkdir(target_dir)
        copy_package_files(source_dir, target_dir)
        capture2e_with_logs("osc ar #{target_dir}")
        capture2e_with_logs("osc commit #{target_dir} -m '#{commit_sha}'")
      end
    end
  end
  
  def copy_package_files(source_dir, target_dir)
    Dir.entries(source_dir).reject { |name| name.start_with?('.') }.each do |file|
      path = File.join(source_dir, file)
      target_path = File.join(target_dir, file)
      if file == '_service'
        copy_service_file(path, target_path)
      else
        FileUtils.cp path, target_path
      end
    end
  end
    
  def copy_service_file(path, target_path)
    File.open(target_path, 'w') do |f|
      f.write(service_file(path))
    end
  end
  
  def service_file(path)
    content = File.read(path)
    xml = Nokogiri::XML(content)
    node = xml.root.at_xpath(".//param[@name='revision']")
    node.content = merge_sha
    xml.to_s
  end
end
