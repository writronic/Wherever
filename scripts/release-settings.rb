#!/usr/bin/ruby
require "json"
require "xcodeproj"

module ReleaseSettings
  class Refusal < StandardError; end

  ROOT = File.expand_path("..", __dir__).freeze
  BUNDLE_ID = "com.writronic.wherever".freeze
  FLOOR = "13.0".freeze
  APPLE_INPUTS = %w[WHEREVER_SIGNING_IDENTITY WHEREVER_APPLE_TEAM_ID].freeze
  SPARKLE_URL = "https://github.com/sparkle-project/Sparkle".freeze
  RESOLVED = "Wherever.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved".freeze

  def self.validate_version(version, build)
    unless version.is_a?(String) && version.match?(/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/) && version.split(".").all? { |part| part.to_i <= 2**64 - 1 }
      raise Refusal, "version: refused; expected a stable numeric major.minor.patch"
    end
    unless build.is_a?(String) && build.match?(/\A[1-9][0-9]*\z/) && build.to_i <= 2**64 - 1
      raise Refusal, "build: refused; expected a positive integer"
    end
  end

  def self.project(root)
    project = Xcodeproj::Project.open(File.join(root, "Wherever.xcodeproj"))
    app = project.targets.find { |target| target.name == "Wherever" }
    raise Refusal, "project: refused; Wherever target missing" unless app
    settings = project.build_settings("Release").merge(app.build_settings("Release"))
    version, build = settings.values_at("MARKETING_VERSION", "CURRENT_PROJECT_VERSION")
    validate_version(version, build)
    raise Refusal, "bundle: refused; unexpected identifier" unless settings["PRODUCT_BUNDLE_IDENTIFIER"] == BUNDLE_ID
    raise Refusal, "deployment: refused; MACOSX_DEPLOYMENT_TARGET must be #{FLOOR}" unless settings["MACOSX_DEPLOYMENT_TARGET"] == FLOOR
    sparkle(root, project)
    [version, build]
  end

  def self.sparkle(root, project)
    remotes = project.root_object.package_references.select { |ref| ref.isa == "XCRemoteSwiftPackageReference" }
    ref = remotes.find { |candidate| candidate.repositoryURL.to_s.sub(/\.git\z/, "") == SPARKLE_URL }
    requirement = ref && ref.requirement
    unless requirement.is_a?(Hash) && requirement["kind"] == "exactVersion" && requirement["version"].to_s.match?(/\A\d+\.\d+\.\d+\z/)
      raise Refusal, "Sparkle: refused; expected an exact version pin"
    end
    resolved = JSON.parse(File.read(File.join(root, RESOLVED)))
    pin = resolved.fetch("pins").find { |entry| entry["identity"].to_s.downcase == "sparkle" }
    unless pin && pin.fetch("state", {})["version"] == requirement["version"]
      raise Refusal, "Sparkle: refused; Package.resolved does not match the exact pin"
    end
  rescue Errno::ENOENT, JSON::ParserError, KeyError
    raise Refusal, "Sparkle: refused; Package.resolved does not match the exact pin"
  end

  def self.newer_build(root, build)
    file = File.join(root, "appcast.xml")
    raise Refusal, "build: refused; appcast.xml is missing" unless File.file?(file)
    last = File.read(file).scan(%r{<sparkle:version>\s*([^<\s]*)\s*</sparkle:version>}).flatten.map { |value| Integer(value, 10) }.max
    return unless last
    raise Refusal, "build: refused; #{build} is not higher than the appcast's last build (#{last})" unless build.to_i > last
  rescue ArgumentError
    raise Refusal, "build: refused; appcast.xml holds a sparkle:version that is not a number"
  end

  def self.keychain_path(path)
    unless path.is_a?(String) && path.start_with?("/") && !path.match?(/[\x00-\x1f\x7f]/) && File.file?(path)
      raise Refusal, "keychain: refused; supply an absolute path to an existing keychain file"
    end
    path
  end

  def self.check_tag(tag, version)
    raise Refusal, "tag: refused; expected v#{version}" unless tag == "v#{version}"
  end

  def self.check_sparkle_key(key)
    raise Refusal, "inputs: refused; SPARKLE_PRIVATE_KEY is not a base64 key" unless key.match?(%r{\A[A-Za-z0-9+/]{20,}={0,2}\z})
  end

  def self.check_info(root)
    info = Xcodeproj::Plist.read_from_path(File.join(root, "Config/Wherever-Info.plist"))
    feed = info["SUFeedURL"]
    raise Refusal, "updates: refused; Info.plist needs an https SUFeedURL" unless feed.is_a?(String) && feed.match?(%r{\Ahttps://[^\s]+\z})
    key = info["SUPublicEDKey"]
    raise Refusal, "updates: refused; Info.plist needs SUPublicEDKey" unless key.is_a?(String) && !key.strip.empty?
    %w[SUEnableAutomaticChecks SUAllowsAutomaticUpdates].each do |name|
      raise Refusal, "updates: refused; #{name} must be false" unless info[name] == false
    end
    feed
  end

  def self.outside_path(path, root)
    raise Refusal, "output: refused; supply an absolute path" unless path.is_a?(String) && path.start_with?("/") && !path.match?(/[\x00-\x1f\x7f]/)
    expanded = File.expand_path(path)
    parent = File.realpath(File.dirname(expanded))
    resolved = File.join(parent, File.basename(expanded))
    repository = File.realpath(root)
    if resolved == repository || resolved.start_with?(repository + "/")
      raise Refusal, "output: refused; path is inside the repository"
    end
    raise Refusal, "output: refused; destination is not a directory" if File.symlink?(resolved) || (File.exist?(resolved) && !File.directory?(resolved))
    resolved
  rescue SystemCallError
    raise Refusal, "output: refused; parent directory must exist"
  end

  def self.inputs(env)
    APPLE_INPUTS.each do |name|
      value = env[name]
      raise Refusal, "inputs: refused; missing or invalid #{name}" unless value.is_a?(String) && !value.strip.empty? && !value.match?(/[\x00-\x1f\x7f]/)
    end
    unless env.fetch("WHEREVER_SIGNING_IDENTITY").match?(/\A(?:[A-Fa-f0-9]{40}|Developer ID Application: .+)\z/)
      raise Refusal, "inputs: refused; supply a named Developer ID Application identity or SHA-1 selector"
    end
    raise Refusal, "inputs: refused; invalid WHEREVER_APPLE_TEAM_ID" unless env.fetch("WHEREVER_APPLE_TEAM_ID").match?(/\A[A-Z0-9]{10}\z/)
  end
end
