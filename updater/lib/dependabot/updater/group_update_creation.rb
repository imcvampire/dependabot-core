# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require "dependabot/dependency_change_builder"
require "dependabot/updater/dependency_group_change_batch"
require "dependabot/workspace"

# This module contains the methods required to build a DependencyChange for
# a single DependencyGroup.
#
# When included in an Operation it expects the following to be available:
# - job: the current Dependabot::Job object
# - dependency_snapshot: the Dependabot::DependencySnapshot of the current state
# - error_handler: a Dependabot::UpdaterErrorHandler to report any problems to
#
module Dependabot
  class Updater
    extend T::Sig

    module GroupUpdateCreation
      extend T::Sig
      extend T::Helpers

      abstract!

      sig { returns(Dependabot::DependencySnapshot) }
      attr_reader :dependency_snapshot

      sig { returns(Dependabot::Updater::ErrorHandler) }
      attr_reader :error_handler

      sig { returns(Dependabot::Job) }
      attr_reader :job

      sig { returns(Dependabot::DependencyGroup) }
      attr_reader :group

      # Returns a Dependabot::DependencyChange object that encapsulates the
      # outcome of attempting to update every dependency iteratively which
      # can be used for PR creation.
      # rubocop:disable Metrics/AbcSize
      # rubocop:disable Metrics/MethodLength
      # rubocop:disable Metrics/PerceivedComplexity
      sig { params(group: Dependabot::DependencyGroup).returns(T.nilable(Dependabot::DependencyChange)) }
      def compile_all_dependency_changes_for(group)
        prepare_workspace

        group_changes = Dependabot::Updater::DependencyGroupChangeBatch.new(
          initial_dependency_files: dependency_snapshot.dependency_files
        )
        original_dependencies = dependency_snapshot.dependencies

        Dependabot.logger.info("Updating the #{job.source.directory} directory.")

        # This array will store any PR notices generated from each checker.
        generated_pr_notices = T.let([], T::Array[Dependabot::UpdateCheckers::Notice])

        group.dependencies.each do |dependency|
          # We still want to update a dependency if it's been updated in another manifest files,
          # but we should skip it if it's been updated in _the same_ manifest file
          if dependency_snapshot.handled_dependencies.include?(dependency.name)
            Dependabot.logger.info(
              "Skipping #{dependency.name} as it has already been handled by a previous group"
            )
            next
          end

          # Get the current state of the dependency files for use in this iteration, filter by directory
          dependency_files = group_changes.current_dependency_files(job)

          # Reparse the current files
          reparsed_dependencies = dependency_file_parser(dependency_files).parse
          dependency = reparsed_dependencies.find { |d| d.name == dependency.name }

          # If the dependency can not be found in the reparsed files then it was likely removed by a previous
          # dependency update
          next if dependency.nil?

          # If the dependency version changed, then we can deduce that the dependency was updated already.
          original_dependency = original_dependencies.find { |d| d.name == dependency.name }
          updated_dependency = deduce_updated_dependency(dependency, original_dependency)
          unless updated_dependency.nil?
            group_changes.add_updated_dependency(updated_dependency)
            next
          end

          updated_dependencies = compile_updates_for(dependency, dependency_files, group, generated_pr_notices)
          next unless updated_dependencies.any?

          lead_dependency = updated_dependencies.find do |dep|
            dep.name.casecmp(dependency.name)&.zero?
          end

          dependency_change = create_change_for(T.must(lead_dependency), updated_dependencies, dependency_files, group)

          # Move on to the next dependency using the existing files if we
          # could not create a change for any reason
          next unless dependency_change

          # Store the updated files for the next loop
          group_changes.merge(dependency_change)
          store_changes(dependency)
        end

        # Create a single Dependabot::DependencyChange that aggregates everything we've updated
        # into a single object we can pass to PR creation.
        dependency_change = Dependabot::DependencyChange.new(
          job: job,
          updated_dependencies: group_changes.updated_dependencies,
          updated_dependency_files: group_changes.updated_dependency_files,
          dependency_group: group,
          notices: generated_pr_notices
        )

        if Experiments.enabled?("dependency_change_validation") && !dependency_change.all_have_previous_version?
          log_missing_previous_version(dependency_change)
          return nil
        end

        dependency_change
      ensure
        cleanup_workspace
      end

      # rubocop:enable Metrics/PerceivedComplexity
      # rubocop:enable Metrics/AbcSize
      # rubocop:enable Metrics/MethodLength
      def log_missing_previous_version(dependency_change)
        deps_no_previous_version = dependency_change.updated_dependencies.reject(&:previous_version).map(&:name)
        deps_no_change = dependency_change.updated_dependencies.reject(&:requirements_changed?).map(&:name)
        msg = "Skipping change to group #{group.name} in directory #{job.source.directory}: "
        if deps_no_previous_version.any?
          msg += "Previous version was not provided for: '#{deps_no_previous_version.join(', ')}' "
        end
        msg += "No requirements change for: '#{deps_no_change.join(', ')}'" if deps_no_change.any?
        Dependabot.logger.info(msg)
      end

      sig { params(dependency_files: T::Array[Dependabot::DependencyFile]).returns(Dependabot::FileParsers::Base) }
      def dependency_file_parser(dependency_files)
        Dependabot::FileParsers.for_package_manager(job.package_manager).new(
          dependency_files: dependency_files,
          repo_contents_path: job.repo_contents_path,
          source: job.source,
          credentials: job.credentials,
          reject_external_code: job.reject_external_code?,
          options: job.experiments
        )
      end

      # This method generates a DependencyChange from the current files and
      # list of dependencies to be updated
      #
      # This method **must** return false in the event of an error
      sig do
        params(
          lead_dependency: Dependabot::Dependency,
          updated_dependencies: T::Array[Dependabot::Dependency],
          dependency_files: T::Array[Dependabot::DependencyFile],
          dependency_group: Dependabot::DependencyGroup
        )
          .returns(T.any(Dependabot::DependencyChange, FalseClass))
      end
      def create_change_for(lead_dependency, updated_dependencies, dependency_files, dependency_group)
        Dependabot::DependencyChangeBuilder.create_from(
          job: job,
          dependency_files: dependency_files,
          updated_dependencies: updated_dependencies,
          change_source: dependency_group
        )
      rescue Dependabot::InconsistentRegistryResponse => e
        error_handler.log_dependency_error(
          dependency: lead_dependency,
          error: e,
          error_type: "inconsistent_registry_response",
          error_detail: e.message
        )

        false
      rescue StandardError => e
        error_handler.handle_dependency_error(error: e, dependency: lead_dependency, dependency_group: dependency_group)

        false
      end

      # This method determines which dependencies must change given a target
      # 'lead' dependency we want to update.
      #
      # This may return more than 1 dependency since the ecosystem-specific
      # tooling may find collaborators which need to be updated in lock-step.
      #
      # This method **must** must return an Array when it errors
      #
      sig do
        params(
          dependency: Dependabot::Dependency,
          dependency_files: T::Array[Dependabot::DependencyFile],
          group: Dependabot::DependencyGroup,
          generated_pr_notices: T::Array[Dependabot::UpdateCheckers::Notice]
        )
          .returns(T::Array[Dependabot::Dependency])
      end
      def compile_updates_for(dependency, dependency_files, group, generated_pr_notices) # rubocop:disable Metrics/MethodLength
        checker = update_checker_for(
          dependency,
          dependency_files,
          group,
          raise_on_ignored: raise_on_ignored?(dependency)
        )

        log_checking_for_update(dependency)

        return [] if all_versions_ignored?(dependency, checker)
        return [] unless semver_rules_allow_grouping?(group, dependency, checker)

        # Consider the dependency handled so no individual PR is raised since it is in this group.
        # Even if update is not possible, etc.
        dependency_snapshot.add_handled_dependencies(dependency.name)

        if checker.up_to_date?
          log_up_to_date(dependency)
          return []
        end

        requirements_to_unlock = requirements_to_unlock(checker)
        log_requirements_for_update(requirements_to_unlock, checker)

        if requirements_to_unlock == :update_not_possible
          Dependabot.logger.info(
            "No update possible for #{dependency.name} #{dependency.version}"
          )
          return []
        end

        updated_dependency = checker.updated_dependencies(
          requirements_to_unlock: requirements_to_unlock
        )

        # Since checker successfully done its job, we can store the pr notices
        if updated_dependency
          pr_notices = checker.generate_pr_notices
          generated_pr_notices.concat(pr_notices) if pr_notices.any?
        end

        updated_dependency
      rescue Dependabot::InconsistentRegistryResponse => e
        dependency_snapshot.add_handled_dependencies(dependency.name)
        error_handler.log_dependency_error(
          dependency: dependency,
          error: e,
          error_type: "inconsistent_registry_response",
          error_detail: e.message
        )
        [] # return an empty set
      rescue StandardError => e
        # If there was an error we might not be able to determine if the dependency is in this
        # group due to semver grouping, so we consider it handled to avoid raising an individual PR.
        dependency_snapshot.add_handled_dependencies(dependency.name)
        error_handler.handle_dependency_error(error: e, dependency: dependency, dependency_group: group)
        [] # return an empty set
      end

      sig { params(dependency: Dependabot::Dependency).void }
      def log_up_to_date(dependency)
        Dependabot.logger.info(
          "No update needed for #{dependency.name} #{dependency.version}"
        )
      end

      sig { params(dependency: Dependabot::Dependency).returns(T::Boolean) }
      def raise_on_ignored?(dependency)
        job.ignore_conditions_for(dependency).any?
      end

      sig do
        params(
          dependency: Dependabot::Dependency,
          dependency_files: T::Array[Dependabot::DependencyFile],
          dependency_group: Dependabot::DependencyGroup,
          raise_on_ignored: T::Boolean
        )
          .returns(Dependabot::UpdateCheckers::Base)
      end
      def update_checker_for(dependency, dependency_files, dependency_group, raise_on_ignored:)
        Dependabot::UpdateCheckers.for_package_manager(job.package_manager).new(
          dependency: dependency,
          dependency_files: dependency_files,
          repo_contents_path: job.repo_contents_path,
          credentials: job.credentials,
          ignored_versions: job.ignore_conditions_for(dependency),
          security_advisories: job.security_advisories_for(dependency),
          raise_on_ignored: raise_on_ignored,
          requirements_update_strategy: job.requirements_update_strategy,
          dependency_group: dependency_group,
          options: job.experiments
        )
      end

      sig { params(dependency: Dependabot::Dependency).void }
      def log_checking_for_update(dependency)
        Dependabot.logger.info(
          "Checking if #{dependency.name} #{dependency.version} needs updating"
        )
        job.log_ignore_conditions_for(dependency)
      end

      sig { params(dependency: Dependabot::Dependency, checker: Dependabot::UpdateCheckers::Base).returns(T::Boolean) }
      def all_versions_ignored?(dependency, checker)
        if job.security_updates_only?
          Dependabot.logger.info("Lowest security fix version is #{checker.lowest_security_fix_version}")
        else
          Dependabot.logger.info("Latest version is #{checker.latest_version}")
        end
        false
      rescue Dependabot::AllVersionsIgnored
        Dependabot.logger.info("All updates for #{dependency.name} were ignored")
        true
      end

      # This method applies "SemVer Grouping" rules: if the latest update is greater than the update-types,
      # then it should not be in the group, but be an individual PR, or in another group that fits it.
      # SemVer Grouping rules have to be applied after we have a checker, because we need to know the latest version.
      # Other rules are applied earlier in the process.
      # rubocop:disable Metrics/AbcSize
      sig do
        params(
          group: Dependabot::DependencyGroup,
          dependency: Dependabot::Dependency,
          checker: Dependabot::UpdateCheckers::Base
        )
          .returns(T::Boolean)
      end
      def semver_rules_allow_grouping?(group, dependency, checker)
        # There are no group rules defined, so this dependency can be included in the group.
        return true unless group.rules["update-types"]

        version_class = Dependabot::Utils.version_class_for_package_manager(job.package_manager)
        unless version_class.correct?(dependency.version.to_s) && version_class.correct?(checker.latest_version)
          return false
        end

        version = version_class.new(dependency.version.to_s)
        latest_version = version_class.new(checker.latest_version)

        # Not every version class implements .major, .minor, .patch so we calculate it here from the segments
        latest = semver_segments(latest_version)
        current = semver_segments(version)
        # Ensure that semver components are of the same type and can be compared with each other.
        return false unless %i(major minor patch).all? { |k| current[k].instance_of?(latest[k].class) }

        return T.must(group.rules["update-types"]).include?("major") if T.must(latest[:major]) > T.must(current[:major])
        return T.must(group.rules["update-types"]).include?("minor") if T.must(latest[:minor]) > T.must(current[:minor])
        return T.must(group.rules["update-types"]).include?("patch") if T.must(latest[:patch]) > T.must(current[:patch])

        # some ecosystems don't do semver exactly, so anything lower gets individual for now
        false
      end
      # rubocop:enable Metrics/AbcSize

      sig { params(version: Gem::Version).returns(T::Hash[Symbol, Integer]) }
      def semver_segments(version)
        {
          major: version.segments[0] || 0,
          minor: version.segments[1] || 0,
          patch: version.segments[2] || 0
        }
      end

      sig { params(checker: Dependabot::UpdateCheckers::Base).returns(Symbol) }
      def requirements_to_unlock(checker)
        if !checker.requirements_unlocked_or_can_be?
          if checker.can_update?(requirements_to_unlock: :none) then :none
          else
            :update_not_possible
          end
        elsif checker.can_update?(requirements_to_unlock: :own) then :own
        elsif checker.can_update?(requirements_to_unlock: :all) then :all
        else
          :update_not_possible
        end
      end

      sig { params(requirements_to_unlock: Symbol, checker: Dependabot::UpdateCheckers::Base).void }
      def log_requirements_for_update(requirements_to_unlock, checker)
        Dependabot.logger.info("Requirements to unlock #{requirements_to_unlock}")

        return unless checker.respond_to?(:requirements_update_strategy)

        Dependabot.logger.info(
          "Requirements update strategy #{checker.requirements_update_strategy&.serialize}"
        )
      end

      sig { params(group: Dependabot::DependencyGroup).void }
      def warn_group_is_empty(group)
        Dependabot.logger.warn(
          "Skipping update group for '#{group.name}' as it does not match any allowed dependencies."
        )

        return unless Dependabot.logger.debug?

        Dependabot.logger.debug(<<~DEBUG.chomp)
          The configuration for this group is:

          #{group.to_config_yaml}
        DEBUG
      end

      sig { void }
      def prepare_workspace
        return unless job.clone? && job.repo_contents_path

        Dependabot::Workspace.setup(
          repo_contents_path: T.must(job.repo_contents_path),
          directory: Pathname.new(job.source.directory || "/").cleanpath
        )
      end

      sig do
        params(dependency: Dependabot::Dependency)
          .returns(T.nilable(T::Array[Dependabot::Workspace::ChangeAttempt]))
      end
      def store_changes(dependency)
        return unless job.clone? && job.repo_contents_path

        Dependabot::Workspace.store_change(memo: "Updating #{dependency.name}")
      end

      sig { void }
      def cleanup_workspace
        return unless job.clone? && job.repo_contents_path

        Dependabot::Workspace.cleanup!
      end

      sig { params(group: Dependabot::DependencyGroup).returns(T::Boolean) }
      def pr_exists_for_dependency_group?(group)
        job.existing_group_pull_requests.any? { |pr| pr["dependency-group-name"] == group.name }
      end

      sig do
        params(
          dependency: T.nilable(Dependabot::Dependency),
          original_dependency: T.nilable(Dependabot::Dependency)
        )
          .returns(T.nilable(Dependabot::Dependency))
      end
      def deduce_updated_dependency(dependency, original_dependency)
        return nil if dependency.nil? || original_dependency.nil?
        return nil if original_dependency.version == dependency.version

        Dependabot.logger.info(
          "Skipping #{dependency.name} as it has already been updated to #{dependency.version}"
        )
        dependency_snapshot.handled_dependencies << dependency.name

        dependency_params = {
          name: dependency.name,
          version: dependency.version,
          previous_version: original_dependency.version,
          requirements: dependency.requirements,
          previous_requirements: original_dependency.requirements,
          package_manager: dependency.package_manager
        }

        Dependabot::Dependency.new(**dependency_params)
      end
    end
  end
end
