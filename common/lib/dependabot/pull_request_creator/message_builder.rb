# frozen_string_literal: true

require "pathname"
require "dependabot/clients/github_with_retries"
require "dependabot/clients/gitlab_with_retries"
require "dependabot/metadata_finders"
require "dependabot/pull_request_creator"

# rubocop:disable Metrics/ClassLength
module Dependabot
  class PullRequestCreator
    class MessageBuilder
      require_relative "message_builder/metadata_presenter"
      require_relative "message_builder/issue_linker"
      require_relative "message_builder/link_and_mention_sanitizer"
      require_relative "pr_name_prefixer"

      attr_reader :source, :dependencies, :files, :credentials,
                  :pr_message_header, :pr_message_footer,
                  :commit_message_options, :vulnerabilities_fixed,
                  :github_redirection_service

      def initialize(source:, dependencies:, files:, credentials:,
                     pr_message_header: nil, pr_message_footer: nil,
                     commit_message_options: {}, vulnerabilities_fixed: {},
                     github_redirection_service: nil)
        @dependencies               = dependencies
        @files                      = files
        @source                     = source
        @credentials                = credentials
        @pr_message_header          = pr_message_header
        @pr_message_footer          = pr_message_footer
        @commit_message_options     = commit_message_options
        @vulnerabilities_fixed      = vulnerabilities_fixed
        @github_redirection_service = github_redirection_service
      end

      def pr_name
        pr_name = pr_name_prefixer.pr_name_prefix
        pr_name += library? ? library_pr_name : application_pr_name
        return pr_name if files.first.directory == "/"

        pr_name + " in #{files.first.directory}"
      end

      def pr_message
        suffixed_pr_message_header + commit_message_intro + \
          metadata_cascades + prefixed_pr_message_footer
      end

      def commit_message
        message = commit_subject + "\n\n"
        message += commit_message_intro
        message += metadata_links
        message += "\n\n" + message_trailers if message_trailers
        message
      end

      private

      def library_pr_name
        pr_name = "update "
        pr_name = pr_name.capitalize if pr_name_prefixer.capitalize_first_word?

        pr_name +
          if dependencies.count == 1
            "#{dependencies.first.display_name} requirement "\
            "#{from_version_msg(old_library_requirement(dependencies.first))}"\
            "to #{new_library_requirement(dependencies.first)}"
          else
            names = dependencies.map(&:name)
            "requirements for #{names[0..-2].join(', ')} and #{names[-1]}"
          end
      end

      def application_pr_name
        pr_name = "bump "
        pr_name = pr_name.capitalize if pr_name_prefixer.capitalize_first_word?

        pr_name +
          if dependencies.count == 1
            dependency = dependencies.first
            "#{dependency.display_name} "\
            "#{from_version_msg(previous_version(dependency))}"\
            "to #{new_version(dependency)}"
          elsif updating_a_property?
            dependency = dependencies.first
            "#{property_name} "\
            "#{from_version_msg(previous_version(dependency))}"\
            "to #{new_version(dependency)}"
          elsif updating_a_dependency_set?
            dependency = dependencies.first
            "#{dependency_set.fetch(:group)} dependency set "\
            "#{from_version_msg(previous_version(dependency))}"\
            "to #{new_version(dependency)}"
          else
            names = dependencies.map(&:name)
            "#{names[0..-2].join(', ')} and #{names[-1]}"
          end
      end

      def pr_name_prefix
        pr_name_prefixer.pr_name_prefix
      end

      def commit_subject
        subject = pr_name.gsub("⬆️", ":arrow_up:").gsub("🔒", ":lock:")
        return subject unless subject.length > 72

        subject = subject.gsub(/ from [^\s]*? to [^\s]*/, "")
        return subject unless subject.length > 72

        subject.split(" in ").first
      end

      def commit_message_intro
        return requirement_commit_message_intro if library?

        version_commit_message_intro
      end

      def prefixed_pr_message_footer
        return "" unless pr_message_footer

        "\n\n#{pr_message_footer}"
      end

      def suffixed_pr_message_header
        return "" unless pr_message_header

        "#{pr_message_header}\n\n"
      end

      def message_trailers
        return unless on_behalf_of_message || signoff_message

        [on_behalf_of_message, signoff_message].compact.join("\n")
      end

      def signoff_message
        signoff_details = commit_message_options[:signoff_details]
        return unless signoff_details.is_a?(Hash)
        return unless signoff_details[:name] && signoff_details[:email]

        "Signed-off-by: #{signoff_details[:name]} <#{signoff_details[:email]}>"
      end

      def on_behalf_of_message
        signoff_details = commit_message_options[:signoff_details]
        return unless signoff_details.is_a?(Hash)
        return unless signoff_details[:org_name] && signoff_details[:org_email]

        "On-behalf-of: @#{signoff_details[:org_name]} "\
        "<#{signoff_details[:org_email]}>"
      end

      def requirement_commit_message_intro
        msg = "Updates the requirements on "

        msg +=
          if dependencies.count == 1
            "#{dependency_links.first} "
          else
            "#{dependency_links[0..-2].join(', ')} and #{dependency_links[-1]} "
          end

        msg + "to permit the latest version."
      end

      # rubocop:disable Metrics/PerceivedComplexity
      def version_commit_message_intro
        if dependencies.count > 1 && updating_a_property?
          return multidependency_property_intro
        end

        if dependencies.count > 1 && updating_a_dependency_set?
          return dependency_set_intro
        end

        return multidependency_intro if dependencies.count > 1

        dependency = dependencies.first
        msg = "Bumps #{dependency_links.first} "\
              "#{from_version_msg(previous_version(dependency))}"\
              "to #{new_version(dependency)}."

        if switching_from_ref_to_release?(dependency)
          msg += " This release includes the previously tagged commit."
        end

        if vulnerabilities_fixed[dependency.name]&.one?
          msg += " **This update includes a security fix.**"
        elsif vulnerabilities_fixed[dependency.name]&.any?
          msg += " **This update includes security fixes.**"
        end

        msg
      end

      # rubocop:enable Metrics/PerceivedComplexity

      def multidependency_property_intro
        dependency = dependencies.first

        "Bumps `#{property_name}` "\
        "#{from_version_msg(previous_version(dependency))}"\
        "to #{new_version(dependency)}."
      end

      def dependency_set_intro
        dependency = dependencies.first

        "Bumps `#{dependency_set.fetch(:group)}` "\
        "dependency set #{from_version_msg(previous_version(dependency))}"\
        "to #{new_version(dependency)}."
      end

      def multidependency_intro
        "Bumps #{dependency_links[0..-2].join(', ')} "\
        "and #{dependency_links[-1]}. These "\
        "dependencies needed to be updated together."
      end

      def from_version_msg(previous_version)
        return "" unless previous_version

        "from #{previous_version} "
      end

      def updating_a_property?
        dependencies.first.
          requirements.
          any? { |r| r.dig(:metadata, :property_name) }
      end

      def updating_a_dependency_set?
        dependencies.first.
          requirements.
          any? { |r| r.dig(:metadata, :dependency_set) }
      end

      def property_name
        @property_name ||= dependencies.first.requirements.
                           find { |r| r.dig(:metadata, :property_name) }&.
                           dig(:metadata, :property_name)

        raise "No property name!" unless @property_name

        @property_name
      end

      def dependency_set
        @dependency_set ||= dependencies.first.requirements.
                            find { |r| r.dig(:metadata, :dependency_set) }&.
                            dig(:metadata, :dependency_set)

        raise "No dependency set!" unless @dependency_set

        @dependency_set
      end

      def dependency_links
        dependencies.map do |dependency|
          if source_url(dependency)
            "[#{dependency.display_name}](#{source_url(dependency)})"
          elsif homepage_url(dependency)
            "[#{dependency.display_name}](#{homepage_url(dependency)})"
          else
            dependency.display_name
          end
        end
      end

      def metadata_links
        if dependencies.count == 1
          return metadata_links_for_dep(dependencies.first)
        end

        dependencies.map do |dep|
          "\n\nUpdates `#{dep.display_name}` "\
          "#{from_version_msg(previous_version(dep))}to "\
          "#{new_version(dep)}"\
          "#{metadata_links_for_dep(dep)}"
        end.join
      end

      def metadata_links_for_dep(dep)
        msg = ""
        msg += "\n- [Release notes](#{releases_url(dep)})" if releases_url(dep)
        msg += "\n- [Changelog](#{changelog_url(dep)})" if changelog_url(dep)
        msg += "\n- [Upgrade guide](#{upgrade_url(dep)})" if upgrade_url(dep)
        msg += "\n- [Commits](#{commits_url(dep)})" if commits_url(dep)
        msg
      end

      def metadata_cascades
        if dependencies.one?
          return metadata_cascades_for_dep(dependencies.first)
        end

        dependencies.map do |dep|
          msg = "\nUpdates `#{dep.display_name}` "\
                "#{from_version_msg(previous_version(dep))}"\
                "to #{new_version(dep)}"

          if vulnerabilities_fixed[dep.name]&.one?
            msg += " **This update includes a security fix.**"
          elsif vulnerabilities_fixed[dep.name]&.any?
            msg += " **This update includes security fixes.**"
          end

          msg + metadata_cascades_for_dep(dep)
        end.join
      end

      def metadata_cascades_for_dep(dependency)
        MetadataPresenter.new(
          dependency: dependency,
          source: source,
          metadata_finder: metadata_finder(dependency),
          vulnerabilities_fixed: vulnerabilities_fixed[dependency.name],
          github_redirection_service: github_redirection_service
        ).to_s
      end

      def source_url(dependency)
        metadata_finder(dependency).source_url
      end

      def homepage_url(dependency)
        metadata_finder(dependency).homepage_url
      end

      def metadata_finder(dependency)
        @metadata_finder ||= {}
        @metadata_finder[dependency.name] ||=
          MetadataFinders.
          for_package_manager(dependency.package_manager).
          new(dependency: dependency, credentials: credentials)
      end

      def pr_name_prefixer
        @pr_name_prefixer ||=
          PrNamePrefixer.new(
            source: source,
            dependencies: dependencies,
            credentials: credentials,
            commit_message_options: commit_message_options,
            security_fix: vulnerabilities_fixed.values.flatten.any?
          )
      end

      def previous_version(dependency)
        # If we don't have a previous version, we *may* still be able to figure
        # one out if a ref was provided and has been changed (in which case the
        # previous ref was essentially the version).
        if dependency.previous_version.nil?
          return ref_changed?(dependency) ? previous_ref(dependency) : nil
        end

        if dependency.previous_version.match?(/^[0-9a-f]{40}$/)
          if ref_changed?(dependency) && previous_ref(dependency)
            return previous_ref(dependency)
          end

          "`#{dependency.previous_version[0..6]}`"
        elsif dependency.version == dependency.previous_version &&
              package_manager == "docker"
          digest = docker_digest_from_reqs(dependency.previous_requirements)
          "`#{digest.split(':').last[0..6]}`"
        else
          dependency.previous_version
        end
      end

      def new_version(dependency)
        if dependency.version.match?(/^[0-9a-f]{40}$/)
          if ref_changed?(dependency) && new_ref(dependency)
            return new_ref(dependency)
          end

          "`#{dependency.version[0..6]}`"
        elsif dependency.version == dependency.previous_version &&
              package_manager == "docker"
          digest = docker_digest_from_reqs(dependency.requirements)
          "`#{digest.split(':').last[0..6]}`"
        else
          dependency.version
        end
      end

      def docker_digest_from_reqs(requirements)
        requirements.
          map { |r| r.dig(:source, "digest") || r.dig(:source, :digest) }.
          compact.first
      end

      def previous_ref(dependency)
        previous_refs = dependency.previous_requirements.map do |r|
          r.dig(:source, "ref") || r.dig(:source, :ref)
        end.compact.uniq
        return previous_refs.first if previous_refs.count == 1
      end

      def new_ref(dependency)
        new_refs = dependency.requirements.map do |r|
          r.dig(:source, "ref") || r.dig(:source, :ref)
        end.compact.uniq
        return new_refs.first if new_refs.count == 1
      end

      def old_library_requirement(dependency)
        old_reqs =
          dependency.previous_requirements - dependency.requirements

        gemspec =
          old_reqs.find { |r| r[:file].match?(%r{^[^/]*\.gemspec$}) }
        return gemspec.fetch(:requirement) if gemspec

        req = old_reqs.first.fetch(:requirement)
        return req if req
        return previous_ref(dependency) if ref_changed?(dependency)
      end

      def new_library_requirement(dependency)
        updated_reqs =
          dependency.requirements - dependency.previous_requirements

        gemspec =
          updated_reqs.find { |r| r[:file].match?(%r{^[^/]*\.gemspec$}) }
        return gemspec.fetch(:requirement) if gemspec

        req = updated_reqs.first.fetch(:requirement)
        return req if req
        if ref_changed?(dependency) && new_ref(dependency)
          return new_ref(dependency)
        end

        raise "No new requirement!"
      end

      def ref_changed?(dependency)
        previous_ref(dependency) != new_ref(dependency)
      end

      def library?
        return true if files.map(&:name).any? { |nm| nm.end_with?(".gemspec") }

        dependencies.any? { |d| previous_version(d).nil? }
      end

      def switching_from_ref_to_release?(dependency)
        unless dependency.previous_version&.match?(/^[0-9a-f]{40}$/) ||
               dependency.previous_version.nil? && previous_ref(dependency)
          return false
        end

        Gem::Version.correct?(dependency.version)
      end

      def package_manager
        @package_manager ||= dependencies.first.package_manager
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength
