require 'octokit'
require 'logger'
require 'yaml'
require_relative 'lib/obs_pull_request_package'
require_relative 'lib/github_status_reporter'

config  = YAML.load_file('config/config.yml')
client  = Octokit::Client.new(config[:credentials])
repository = config[:github][:repository]
logger  = Logger.new(STDOUT)
logger.level = Logger::DEBUG
 
def line_seperator(pull_request)
  '=' * 15 + " #{pull_request.title} (#{pull_request.number}) " + '=' * 15
end

new_projects = []
client.pull_requests(repository).each do |pull_request|
  next if pull_request.base.ref != 'master'

  logger.info('')
  logger.info(line_seperator(pull_request))
  project = ObsPullRequestPackage.new(pull_request: pull_request, logger: logger, config: config)
  project.create
  
  GitHubStatusReporter.new(project: project, client: client, logger: logger, repository: repository).report
  new_projects << project
end

ObsPullRequestPackage.all(logger, config).each do |obs_project|
  next if new_projects.any? { |pr_project| pr_project.pull_request.number == obs_project.pull_request.number }
  obs_project.delete
end
