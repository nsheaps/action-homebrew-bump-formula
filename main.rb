# frozen_string_literal: true

require 'formula'

class Object
  def false?
    nil?
  end
end

class String
  def false?
    empty? || strip == 'false'
  end
end

module Homebrew
  module_function

  def print_command(*cmd)
    puts "[command]#{cmd.join(' ').gsub("\n", ' ')}"
  end

  def brew(*args)
    print_command ENV["HOMEBREW_BREW_FILE"], *args
    safe_system ENV["HOMEBREW_BREW_FILE"], *args
  end

  def git(*args)
    print_command ENV["HOMEBREW_GIT"], *args
    safe_system ENV["HOMEBREW_GIT"], *args
  end

  def read_brew(*args)
    print_command ENV["HOMEBREW_BREW_FILE"], *args
    output = `#{ENV["HOMEBREW_BREW_FILE"]} #{args.join(' ')}`.chomp
    odie output if $CHILD_STATUS.exitstatus != 0
    output
  end

  # Get inputs
  message = ENV['HOMEBREW_BUMP_MESSAGE']
  org = ENV['HOMEBREW_BUMP_ORG']
  no_fork = ENV['HOMEBREW_BUMP_NO_FORK']
  tap = ENV['HOMEBREW_BUMP_TAP']
  formula = ENV['HOMEBREW_BUMP_FORMULA']
  tag = ENV['HOMEBREW_BUMP_TAG']
  revision = ENV['HOMEBREW_BUMP_REVISION']
  force = ENV['HOMEBREW_BUMP_FORCE']
  livecheck = ENV['HOMEBREW_BUMP_LIVECHECK']
  use_github_actions_user = ENV['HOMEBREW_COMMIT_AUTHOR_GITHUB_ACTIONS_USER'] == 'true'
  use_sender_user = ENV['HOMEBREW_COMMIT_AUTHOR_SENDER_USER'] == 'true'

  # Check inputs
  if livecheck.false?
    odie "Need 'formula' input specified" if formula.blank?
    odie "Need 'tag' input specified" if tag.blank?
  end

  # Get user details
  if use_github_actions_user
    # gh api \
    # -H "Accept: application/vnd.github+json" \
    # -H "X-GitHub-Api-Version: 2022-11-28" \
    # "/users/github-actions[bot]"
    user = {}
    user['id'] = 41898282,
    user['login'] = 'github-actions[bot]'
    user['name'] = 'Github Actions'
    user['email'] = 'github-actions[bot]@users.noreply.github.com'
    user_name = user['login']
    user_email = user['email']
  elsif use_sender_user
    user = {}
    user['id'] = ENV['GITHUB_SENDER_ID'].to_i
    user['login'] = ENV['GITHUB_SENDER_LOGIN']
    user['name'] = ENV['GITHUB_SENDER_NAME']
    user['email'] = ENV['GITHUB_SENDER_EMAIL']
    user_name = user['name'] || user['login']
    user_email = user['email'] || "#{user['login']}@users.noreply.github.com"
  else
    user = GitHub::API.open_rest "#{GitHub::API_URL}/user"
    user_id = user['id']
    user_login = user['login']
    user_name = user['name'] || user['login']
    user_email = user['email'] || (
      # https://help.github.com/en/github/setting-up-and-managing-your-github-user-account/setting-your-commit-email-address
      user_created_at = Date.parse user['created_at']
      plus_after_date = Date.parse '2017-07-18'
      need_plus_email = (user_created_at - plus_after_date).positive?
      user_email = "#{user_login}@users.noreply.github.com"
      user_email = "#{user_id}+#{user_email}" if need_plus_email
      user_email
    )
  end

  # Tell git who you are
  git 'config', '--global', 'user.name', user_name
  git 'config', '--global', 'user.email', user_email

  # Always tap homebrew/core, otherwise brew can't find formulae
  brew 'tap', 'homebrew/core'
  
  # Tap the requested tap if applicable
  brew 'tap', tap unless tap.blank?

  # If tap is not blank and no_fork is true, go to the local tap and set the
  # token in the URL for authentication so it's not asked later
  if !tap.blank? && !no_fork.false?
    # go to the local tap checkout
    current_dir = Dir.pwd
    tap_clone_location = read_brew '--repo', tap
    Dir.chdir tap_clone_location
    
    # get the current upstream url for the tap
    tap_repo_origin = `git config --get remote.origin.url`.chomp
    tap_repo_origin = tap_repo_origin.gsub('https://', "https://x-access-token:#{ENV["HOMEBREW_GITHUB_API_TOKEN"]}@")

    # set the new url with the token in it
    git 'remote', 'set-url', 'origin', tap_repo_origin
    git 'config', 'push.default', 'current'

    if !force.false?
      # make sure .git/hooks exists
      FileUtils.mkdir_p '.git/hooks'
      f = File.new('.git/hooks/pre-commit', 'w')
      f.puts '#!/bin/bash'
      f.puts '# Force push when the pre-push hook is triggered'
      f.puts 'git push --force "$@"'
      f.close
      # make the file executable
      File.chmod(0755, '.git/hooks/pre-commit')
    end

    # go back to the original directory
    Dir.chdir current_dir
  end

  # Append additional PR message
  message = if message.blank?
              ''
            else
              message + "\n\n"
            end
  message += '[`action-homebrew-bump-formula`](https://github.com/dawidd6/action-homebrew-bump-formula)'

  # Do the livecheck stuff or not
  if livecheck.false?
    # Change formula name to full name
    formula = tap + '/' + formula if !tap.blank? && !formula.blank?

    # Get info about formula
    stable = Formula[formula].stable
    is_git = stable.downloader.is_a? GitDownloadStrategy

    # Prepare tag and url
    tag = tag.delete_prefix 'refs/tags/'
    version = Version.parse tag

    # Finally bump the formula
    brew 'bump-formula-pr',
         '--no-audit',
         '--no-browse',
         "--message=#{message}",
         *("--fork-org=#{org}" unless org.blank?),
         *("--no-fork" unless no_fork.false?),
         *("--version=#{version}" unless is_git),
         *("--tag=#{tag}" if is_git),
         *("--revision=#{revision}" if is_git),
         *('--force' unless force.false?),
         formula
  else
    # Support multiple formulae in input and change to full names if tap
    unless formula.blank?
      formula = formula.split(/[ ,\n]/).reject(&:blank?)
      formula = formula.map { |f| tap + '/' + f } unless tap.blank?
    end

    # Get livecheck info
    json = read_brew 'livecheck',
                     '--formula',
                     '--quiet',
                     '--newer-only',
                     '--full-name',
                     '--json',
                     *("--tap=#{tap}" if !tap.blank? && formula.blank?),
                     *(formula unless formula.blank?)
    json = JSON.parse json

    # Define error
    err = nil

    # Loop over livecheck info
    json.each do |info|
      # Skip if there is no version field
      next unless info['version']

      # Get info about formula
      formula = info['formula']
      version = info['version']['latest']

      begin
        # Finally bump the formula
        brew 'bump-formula-pr',
             '--no-audit',
             '--no-browse',
             "--message=#{message}",
             "--version=#{version}",
             *("--fork-org=#{org}" unless org.blank?),
             *("--no-fork" unless no_fork.false?),
             *('--force' unless force.false?),
             formula
      rescue ErrorDuringExecution => e
        # Continue execution on error, but save the exeception
        err = e
      end
    end

    # Die if error occured
    odie err if err
  end
end
