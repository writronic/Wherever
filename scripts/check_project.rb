#!/usr/bin/ruby

require "json"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
SPARKLE_URL = "https://github.com/sparkle-project/Sparkle".freeze
SPARKLE_VERSION = "2.10.1".freeze
BANNED_PLIST = %w[SUScheduledCheckInterval SUAutomaticallyUpdate SUEnableSystemProfiling].freeze
BANNED_SOURCE = [/checkForUpdatesInBackground/, /automaticallyDownloadsUpdates\s*=/].freeze
AUTO_CHECK_SOURCE = /automaticallyChecksForUpdates\s*=/.freeze
TARGETS = %w[Wherever WhereverHelper WhereverKit WhereverKitTests WhereverTests].freeze
SHARED_FOLDER = "WhereverShared".freeze
APPS = %w[Wherever WhereverHelper].freeze
REGIONS = %w[Base en tr de fr es ru nl ja zh-Hans ar pl].freeze
SHARED = {
  "SWIFT_VERSION" => "6.0",
  "SWIFT_STRICT_CONCURRENCY" => "complete",
  "SWIFT_TREAT_WARNINGS_AS_ERRORS" => "YES",
  "GCC_TREAT_WARNINGS_AS_ERRORS" => "YES",
  "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY" => "YES",
  "SWIFT_APPROACHABLE_CONCURRENCY" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "MARKETING_VERSION" => "0.1.0",
  "CURRENT_PROJECT_VERSION" => "1",
  "CODE_SIGN_STYLE" => "Automatic",
  "DEVELOPMENT_TEAM" => "SP495GG2KZ",
}.freeze
PER_TARGET = {
  "Wherever" => {
    "MACOSX_DEPLOYMENT_TARGET" => "13.0", "SWIFT_DEFAULT_ACTOR_ISOLATION" => "MainActor",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.writronic.wherever", "SKIP_INSTALL" => "NO", "GENERATE_INFOPLIST_FILE" => "NO",
    "ENABLE_HARDENED_RUNTIME" => "YES", "INFOPLIST_FILE" => "Config/Wherever-Info.plist",
    "CODE_SIGN_ENTITLEMENTS" => "Config/Wherever.entitlements", "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  },
  "WhereverHelper" => {
    "MACOSX_DEPLOYMENT_TARGET" => "13.0", "SWIFT_DEFAULT_ACTOR_ISOLATION" => "MainActor",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.writronic.wherever.helper", "SKIP_INSTALL" => "YES", "GENERATE_INFOPLIST_FILE" => "NO",
    "ENABLE_HARDENED_RUNTIME" => "YES", "INFOPLIST_FILE" => "Config/WhereverHelper-Info.plist", "CODE_SIGN_ENTITLEMENTS" => nil,
  },
  "WhereverKit" => {
    "MACOSX_DEPLOYMENT_TARGET" => "13.0", "SWIFT_DEFAULT_ACTOR_ISOLATION" => "nonisolated",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.writronic.wherever.kit", "SKIP_INSTALL" => "YES", "GENERATE_INFOPLIST_FILE" => "YES",
  },
  "WhereverKitTests" => {
    "MACOSX_DEPLOYMENT_TARGET" => "14.0", "SWIFT_DEFAULT_ACTOR_ISOLATION" => "nonisolated",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.writronic.wherever.kit.tests", "SKIP_INSTALL" => "YES", "GENERATE_INFOPLIST_FILE" => "YES",
    "TEST_HOST" => nil,
  },
  "WhereverTests" => {
    "MACOSX_DEPLOYMENT_TARGET" => "14.0", "SWIFT_DEFAULT_ACTOR_ISOLATION" => "MainActor",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.writronic.wherever.tests", "SKIP_INSTALL" => "YES", "GENERATE_INFOPLIST_FILE" => "YES",
    "TEST_HOST" => "$(BUILT_PRODUCTS_DIR)/Wherever.app/Contents/MacOS/Wherever", "BUNDLE_LOADER" => "$(TEST_HOST)",
  },
}.freeze

project = Xcodeproj::Project.open(File.join(ROOT, "Wherever.xcodeproj"))
failures = []

failures << "objectVersion is #{project.object_version}, expected 77" unless project.object_version == "77"
regions = project.root_object.known_regions
failures << "known regions are #{regions.inspect}, expected #{REGIONS.inspect}" unless regions.sort == REGIONS.sort

names = project.targets.map(&:name).sort
failures << "targets are #{names.inspect}, expected #{TARGETS.sort.inspect}" unless names == TARGETS.sort

project.targets.each do |target|
  expected = SHARED.merge(PER_TARGET.fetch(target.name, {}))
  %w[Debug Release].each do |config|
    settings = project.build_settings(config).merge(target.build_settings(config))
    expected.each do |key, want|
      got = settings[key]
      failures << "#{target.name}/#{config} #{key}=#{got.inspect}, expected #{want.inspect}" unless got == want
    end
    failures << "#{target.name}/#{config} ENABLE_APP_SANDBOX=YES; Wherever is not sandboxed" if settings["ENABLE_APP_SANDBOX"] == "YES"
  end
  folders = target.file_system_synchronized_groups.map(&:path)
  wanted_folders = APPS.include?(target.name) ? [target.name, SHARED_FOLDER] : [target.name]
  failures << "#{target.name} synchronized folders are #{folders.inspect}, expected #{wanted_folders.inspect}" unless folders == wanted_folders
  linked = target.package_product_dependencies.map(&:product_name).sort
  wanted = { "Wherever" => %w[Sparkle WhereverInterface], "WhereverHelper" => [] }.fetch(target.name, ["WhereverInterface"])
  failures << "#{target.name} links #{linked.inspect}, expected #{wanted.inspect}" unless linked == wanted
  debug = project.build_settings("Debug").merge(target.build_settings("Debug"))
  puts "#{target.name}: macOS #{debug['MACOSX_DEPLOYMENT_TARGET']}, Swift #{debug['SWIFT_VERSION']}, #{debug['SWIFT_DEFAULT_ACTOR_ISOLATION']}, #{debug['PRODUCT_BUNDLE_IDENTIFIER']}"
end

synced = project.objects.select { |o| o.isa == "PBXFileSystemSynchronizedRootGroup" }.map(&:path).sort
wanted_synced = (TARGETS + [SHARED_FOLDER]).sort
failures << "synchronized folders are #{synced.inspect}, expected #{wanted_synced.inspect}" unless synced == wanted_synced
packages = project.root_object.package_references.map do |r|
  r.respond_to?(:relative_path) ? [r.isa, r.relative_path] : [r.isa, r.repositoryURL, r.requirement]
end
want_packages = [
  ["XCLocalSwiftPackageReference", "Packages/WhereverInterface"],
  ["XCRemoteSwiftPackageReference", SPARKLE_URL, { "kind" => "exactVersion", "version" => SPARKLE_VERSION }],
]
failures << "package references are #{packages.inspect}, expected #{want_packages.inspect}" unless packages == want_packages
resolved = JSON.parse(File.read(File.join(ROOT, "Wherever.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")))
pins = resolved["pins"].map { |pin| [pin["identity"], pin.dig("state", "version")] }
failures << "Package.resolved pins #{pins.inspect}, expected sparkle at #{SPARKLE_VERSION} only" unless pins == [["sparkle", SPARKLE_VERSION]]

app = project.targets.find { |target| target.name == "Wherever" }
embedded = app && app.copy_files_build_phases.select { |phase| phase.dst_subfolder_spec == "10" }.flat_map(&:files)
  .find { |file| file.file_ref && file.file_ref.path == "WhereverKit.framework" }
failures << "Wherever must embed WhereverKit.framework with CodeSignOnCopy" unless embedded && embedded.settings.to_h.fetch("ATTRIBUTES", []).include?("CodeSignOnCopy")
tool_phase = app && app.copy_files_build_phases.find { |phase| phase.name == "Embed Command-Line Tool" }
if tool_phase.nil? || tool_phase.dst_subfolder_spec != "1" || tool_phase.dst_path != "Contents/Helpers"
  failures << "Wherever must copy the command-line tool in an \"Embed Command-Line Tool\" phase to Wrapper, Contents/Helpers"
else
  tool_files = tool_phase.files.map { |file| file.file_ref&.path }
  failures << "Embed Command-Line Tool copies #{tool_files.inspect}, expected [\"WhereverKit/Engine/wherever\"]" unless tool_files == ["WhereverKit/Engine/wherever"]
  failures << "Embed Command-Line Tool must sign the tool on copy" unless tool_phase.files.all? { |file| file.settings.to_h.fetch("ATTRIBUTES", []).include?("CodeSignOnCopy") }
end
helper_phase = app && app.copy_files_build_phases.find { |phase| phase.name == "Embed Login Item" }
if helper_phase.nil? || helper_phase.dst_subfolder_spec != "1" || helper_phase.dst_path != "Contents/Library/LoginItems"
  failures << "Wherever must copy the helper in an \"Embed Login Item\" phase to Wrapper, Contents/Library/LoginItems"
else
  helper_files = helper_phase.files.map { |file| file.file_ref&.path }
  failures << "Embed Login Item copies #{helper_files.inspect}, expected [\"WhereverHelper.app\"]" unless helper_files == ["WhereverHelper.app"]
  failures << "Embed Login Item must sign the helper on copy" unless helper_phase.files.all? { |file| file.settings.to_h.fetch("ATTRIBUTES", []).include?("CodeSignOnCopy") }
end
failures << "Wherever must depend on WhereverHelper" unless app && app.dependencies.any? { |dependency| dependency.target&.name == "WhereverHelper" }
kit = project.targets.find { |target| target.name == "WhereverKit" }
kit_exceptions = kit ? kit.file_system_synchronized_groups.flat_map(&:exceptions).select { |set| set.target == kit }.flat_map(&:membership_exceptions) : []
failures << "WhereverKit membership exceptions are #{kit_exceptions.inspect}; Engine/wherever must be one, or the framework copies the tool" unless kit_exceptions.include?("Engine/wherever")
cli_version = File.read(File.join(ROOT, "Engine/wherever-cli/Cargo.toml"))[/^version = "([^"]+)"/, 1]
failures << "wherever-cli version is #{cli_version.inspect}, expected MARKETING_VERSION #{SHARED['MARKETING_VERSION']}" unless cli_version == SHARED["MARKETING_VERSION"]
project.targets.each do |target|
  target.copy_files_build_phases.each do |phase|
    phase.files.each { |file| failures << "#{target.name} copies package product #{file.product_ref.product_name} in #{phase.name}; the Frameworks link already embeds it" if file.product_ref }
  end
end

info = Xcodeproj::Plist.read_from_path(File.join(ROOT, "Config/Wherever-Info.plist"))
{ "CFBundleShortVersionString" => "$(MARKETING_VERSION)", "CFBundleVersion" => "$(CURRENT_PROJECT_VERSION)" }.each do |key, want|
  failures << "Info.plist #{key}=#{info[key].inspect}, expected #{want}" unless info[key] == want
end
%w[SUFeedURL SUPublicEDKey].each do |key|
  failures << "Info.plist #{key} is empty" unless info[key].is_a?(String) && !info[key].strip.empty?
end
%w[SUEnableAutomaticChecks SUAllowsAutomaticUpdates].each do |key|
  failures << "Info.plist #{key}=#{info[key].inspect}, expected false" unless info[key] == false
end
failures << "Wherever-Info.plist LSUIElement=#{info['LSUIElement'].inspect}, expected true" unless info["LSUIElement"] == true
BANNED_PLIST.each { |key| failures << "Info.plist holds #{key}" if info.key?(key) }
helper_info = Xcodeproj::Plist.read_from_path(File.join(ROOT, "Config/WhereverHelper-Info.plist"))
failures << "WhereverHelper-Info.plist LSUIElement=#{helper_info['LSUIElement'].inspect}, expected true" unless helper_info["LSUIElement"] == true
BANNED_PLIST.each { |key| failures << "WhereverHelper-Info.plist holds #{key}" if helper_info.key?(key) }
Dir.glob(File.join(ROOT, "{Wherever,WhereverHelper,WhereverShared}/**/*.swift")).sort.each do |path|
  text = File.read(path)
  name = path.delete_prefix("#{ROOT}/")
  BANNED_SOURCE.each { |banned| failures << "#{name} holds #{banned.source}; only Sparkle's own scheduler may check in the background, and nothing downloads or installs unasked" if text.match?(banned) }
  failures << "#{name} holds #{AUTO_CHECK_SOURCE.source}; only Wherever/WhereverApp.swift may set it, from the Settings switch" if name != "Wherever/WhereverApp.swift" && text.match?(AUTO_CHECK_SOURCE)
  failures << "#{name} imports Sparkle; only Wherever/WhereverApp.swift may" if name != "Wherever/WhereverApp.swift" && text.match?(/^\s*(@\w+\s+)?import\s+Sparkle\b/)
end
entitlements = Xcodeproj::Plist.read_from_path(File.join(ROOT, "Config/Wherever.entitlements"))
failures << "entitlements hold #{entitlements.keys.inspect}, expected 0 keys" unless entitlements.empty?
puts "release policy: #{TARGETS.length} targets, #{TARGETS.length * 2} configurations, version 0.1.0 (1), hardened runtime, no sandbox, #{entitlements.size} entitlement keys, " \
     "Sparkle #{SPARKLE_VERSION}, manual by default (SUFeedURL #{info['SUFeedURL']}, SUPublicEDKey #{info['SUPublicEDKey']}, " \
     "SUEnableAutomaticChecks #{info['SUEnableAutomaticChecks']}, SUAllowsAutomaticUpdates #{info['SUAllowsAutomaticUpdates']})"

if failures.empty?
  puts "check_project: OK"
else
  failures.each { |f| warn "check_project: #{f}" }
  exit 1
end
