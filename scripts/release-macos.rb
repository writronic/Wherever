#!/usr/bin/ruby
require "cfpropertylist"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require_relative "release-settings"

module MacRelease
  Refusal = ReleaseSettings::Refusal
  ARCHITECTURES = %w[arm64 x86_64].freeze
  NOTARY_PROFILE = "Wherever".freeze
  DEFAULT_OUTPUT = File.expand_path("~/Desktop/Wherever release").freeze
  LICENSE = "LICENSE"
  FLOOR = ReleaseSettings::FLOOR
  DOWNLOAD = "https://github.com/writronic/Wherever/releases/download/v%s/".freeze
  SPARKLE_BIN = "SourcePackages/artifacts/sparkle/Sparkle/bin".freeze
  KEYCHAIN_ACCOUNT = ["--account", "wherever"].freeze
  MINIMUM = "<sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>".freeze
  DIAGNOSTIC = /:[0-9]+:[0-9]+: (?:warning|error): |^<unknown>:[0-9]+: (?:warning|error): |(?:^| )ld: (?:warning|error): |\.xcodeproj: (?:warning|error): /.freeze

  def self.kept(env)
    env["WHEREVER_RELEASE_BUILD"].to_s.empty? ? File.expand_path("~/Library/Developer/Wherever-build/release") : env["WHEREVER_RELEASE_BUILD"]
  end

  def self.sanitize(text, env, sparkle_key = nil)
    result = text.to_s.dup
    (ReleaseSettings::APPLE_INPUTS.map { |name| env[name] } << sparkle_key).compact.reject(&:empty?).sort_by { |value| -value.length }.each { |value| result.gsub!(value, "[redacted]") }
    result.gsub(/Developer ID Application:[^\r\n]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, "[redacted]")
  end

  def self.notary_result(raw, exit_code)
    data = JSON.parse(raw)
    data = {} unless data.is_a?(Hash)
    id = data["id"]
    id = nil unless id.is_a?(String) && id.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
    status = %w[Accepted Invalid Rejected].include?(data["status"]) ? data["status"] : "Unknown"
    status = "In Progress" if data["status"] == "In Progress"
    { "id" => id, "status" => status, "accepted" => exit_code == 0 && status == "Accepted" && !id.nil? }
  rescue JSON::ParserError
    { "id" => nil, "status" => "Unknown", "accepted" => false }
  end

  def self.notary_log(raw)
    data = JSON.parse(raw)
    issues = data.is_a?(Hash) && data["issues"].is_a?(Array) ? data["issues"] : []
    { "issue_count" => issues.length, "issues" => issues.map do |issue|
      issue = {} unless issue.is_a?(Hash)
      { "severity" => %w[error warning].include?(issue["severity"]) ? issue["severity"] : "unknown",
        "code" => issue["code"].is_a?(Integer) ? issue["code"] : nil,
        "architecture" => ARCHITECTURES.include?(issue["architecture"]) ? issue["architecture"] : nil }
    end }
  rescue JSON::ParserError
    { "issue_count" => nil, "issues" => [] }
  end

  def self.check_architectures(text)
    found = text.split
    unless (ARCHITECTURES - found).empty? && (found - ARCHITECTURES).empty? && found.uniq == found
      raise Refusal, "architectures: refused; require #{ARCHITECTURES.join(' and ')}"
    end
  end

  def self.check_minimum(text, exact = false)
    commands = text.split(/Load command \d+/).select { |part| part.match?(/cmd LC_(?:BUILD_VERSION|VERSION_MIN_MACOSX)\b/) }
    raise Refusal, "deployment: refused; missing macOS load command" if commands.empty?
    commands.each do |part|
      if part.include?("LC_BUILD_VERSION") && !part.match?(/platform\s+(?:1|MACOS)\b/)
        raise Refusal, "deployment: refused; non-macOS image"
      end
      version = part[/\b(?:minos|version)\s+([0-9]+(?:\.[0-9]+){0,2})\b/, 1]
      pieces = version && version.split(".").map(&:to_i)
      raise Refusal, "deployment: refused; no minimum version" unless pieces
      order = pieces.fill(0, pieces.length...3) <=> [13, 0, 0]
      raise Refusal, "deployment: refused; minimum exceeds macOS #{FLOOR}" if order > 0
      raise Refusal, "deployment: refused; minimum must be macOS #{FLOOR}" if exact && order != 0
    end
  end

  def self.check_bundle(info, version, build)
    unless info["CFBundleIdentifier"] == ReleaseSettings::BUNDLE_ID && info["CFBundleShortVersionString"] == version &&
           info["CFBundleVersion"] == build && info["CFBundleExecutable"] == "Wherever" && info["LSMinimumSystemVersion"] == FLOOR
      raise Refusal, "bundle: refused; identifier, executable, version, build or LSMinimumSystemVersion mismatch"
    end
  end

  DMG_TRIES = 3
  DMG_PAUSE = 5

  CREATE_DMG_MISSING = "create-dmg: refused; run npm install --global create-dmg@8.1.0 --allow-scripts=fs-xattr,macos-alias"

  def self.dmg_command(app, folder)
    ["create-dmg", "--no-code-sign", "--dmg-title=Wherever", "--no-version-in-filename", app, folder]
  end

  def self.attribute(tag, name)
    tag[/#{Regexp.escape(name)}="([^"]*)"/, 1]
  end

  def self.pin_minimum(text)
    tag = %r{<sparkle:minimumSystemVersion>\s*([^<]*?)\s*</sparkle:minimumSystemVersion>}
    found = text.match(tag)
    unless found
      raise Refusal, "appcast: refused; no item to hold minimumSystemVersion" unless text.include?("</item>")
      return [text.sub("</item>", "  #{MINIMUM}\n</item>"), "added"]
    end
    return [text, "tool"] if found[1] == "13.0.0"
    return [text.sub(tag, MINIMUM), "normalized"] if found[1] == "13.0"
    raise Refusal, "appcast: refused; minimumSystemVersion is not 13.0.0"
  end

  def self.check_appcast(text, version, build, signature = nil, length = nil)
    raise Refusal, "appcast: refused; expected exactly one item" unless text.scan(/<item[ >]/).length == 1
    raise Refusal, "appcast: refused; sparkle:version is not the build" unless text.match?(%r{<sparkle:version>\s*#{Regexp.escape(build)}\s*</sparkle:version>})
    raise Refusal, "appcast: refused; sparkle:shortVersionString is not the version" unless text.match?(%r{<sparkle:shortVersionString>\s*#{Regexp.escape(version)}\s*</sparkle:shortVersionString>})
    raise Refusal, "appcast: refused; sparkle:minimumSystemVersion is not 13.0.0" unless text.match?(%r{<sparkle:minimumSystemVersion>\s*13\.0\.0\s*</sparkle:minimumSystemVersion>})
    tag = text[/<enclosure\b[^>]*>/m].to_s
    raise Refusal, "appcast: refused; enclosure url is not the release download" unless attribute(tag, "url") == "#{format(DOWNLOAD, version)}Wherever.dmg"
    raise Refusal, "appcast: refused; enclosure has no length" unless attribute(tag, "length").to_s.match?(/\A[1-9][0-9]*\z/)
    raise Refusal, "appcast: refused; enclosure has no sparkle:edSignature" if attribute(tag, "sparkle:edSignature").to_s.empty?
    return unless signature
    unless attribute(tag, "sparkle:edSignature") == signature && attribute(tag, "length") == length
      raise Refusal, "appcast: refused; enclosure differs from sign_update"
    end
  end

  def self.fill_cask(template, version, sha256, feed)
    template.sub("@VERSION@", version).sub("@SHA256@", sha256).sub("@FEED_URL@", feed)
  end

  CASK_ORDER = [
    /^  version "\d+\.\d+\.\d+"$/, /^  sha256 "[0-9a-f]{64}"$/,
    %r{^  url "https://github.com/writronic/Wherever/releases/download/v\#\{version\}/Wherever\.dmg"$},
    /^  name "Wherever"$/, /^  desc "/, /^  homepage "https:/, /^  livecheck do$/, /^    strategy :sparkle, &:short_version$/,
    /^  auto_updates true$/, /^  depends_on macos: :ventura$/, /^  app "Wherever\.app"$/,
    /^  uninstall quit: \["com\.writronic\.wherever\.helper", "com\.writronic\.wherever"\]$/, /^  zap trash: \[$/,
    %r{^    "~/Library/Preferences/com\.writronic\.wherever\.helper\.plist",$}
  ].freeze

  def self.check_cask(text)
    lines = text.lines.map(&:chomp)
    at = -1
    CASK_ORDER.each do |pattern|
      index = lines.each_index.find { |i| i > at && lines[i].match?(pattern) }
      raise Refusal, "cask: refused; stanza missing or out of order: #{pattern.source[0, 40]}" unless index
      at = index
    end
    raise Refusal, "cask: refused; depends_on must be macos: :ventura" if text.match?(/depends_on macos: ">=|depends_on macos: :ventura\S/)
    raise Refusal, "cask: refused; unfilled placeholder" if text.include?("@")
    _out, _err, status = Open3.capture3(RbConfig.ruby, "-c", stdin_data: text)
    raise Refusal, "cask: refused; ruby -c rejects the file" unless status.success?
  end

  class Run
    def initialize(root, env = ENV, output = $stdout)
      @root = File.realpath(root)
      @env = env
      @output = output
      @build_started = false
      @notary_started = false
      @finished = false
      @record = {}
    end

    def say(text)
      @output.puts(MacRelease.sanitize(text, @env, @sparkle_key))
    end

    def keychain_args
      @keychain ? ["--keychain", @keychain] : []
    end

    def tool(name, missing = "tools: refused; #{name} not found")
      return name if name.include?("/")
      dir = (@env["PATH"] || ENV["PATH"]).to_s.split(File::PATH_SEPARATOR).find { |candidate| File.executable?(File.join(candidate, name)) && !File.directory?(File.join(candidate, name)) }
      raise Refusal, missing unless dir
      File.join(dir, name)
    end

    def capture(*args, chdir: @root, env: {}, stdin: "")
      environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
      environment.merge!("GIT_TERMINAL_PROMPT" => "0", "GIT_NO_REPLACE_OBJECTS" => "1", "XCODE_XCCONFIG_FILE" => nil)
      environment.merge!(env)
      stdout, stderr, status = Open3.capture3(environment, tool(args.first), *args.drop(1), chdir: chdir, stdin_data: stdin)
      [stdout, stderr, status.exitstatus || 1]
    end

    def command(label, *args, chdir: @root, env: {}, quiet: false, show: false, stdin: "")
      stdout, stderr, code = capture(*args, chdir: chdir, env: env, stdin: stdin)
      say "#{label}: exit #{code}" unless quiet && code == 0
      if code != 0
        (stdout + stderr).lines.last(30).each { |line| say("  #{line.chomp}") } if show
        raise Refusal, "#{label}: failed; private tool details omitted"
      end
      [stdout, stderr]
    end

    def git(*args)
      stdout, _stderr, code = capture("/usr/bin/git", *args)
      raise Refusal, "source: refused; git check failed" unless code == 0
      stdout.strip
    end

    def clean_source
      if git("ls-files", "-v", "-z", "--", ".").split("\0").any? { |entry| entry.match?(/\A[a-zS] /) }
        raise Refusal, "source: refused; build inputs use assume-unchanged or skip-worktree"
      end
      raise Refusal, "source: refused; tracked tree is dirty" unless git("status", "--porcelain", "--untracked-files=no").empty?
      raise Refusal, "source: refused; untracked build inputs" unless git("ls-files", "--others", "--exclude-standard", "--", ".").empty?
      raise Refusal, "source: refused; ignored Swift files" unless git("ls-files", "--others", "--ignored", "--exclude-standard", "--", "*.swift").empty?
    end

    def preflight(arguments)
      command("icon catalog", "/usr/bin/ruby", File.join(@root, "scripts/check-icons.rb"), show: true)
      raise Refusal, "environment: refused; XCODE_XCCONFIG_FILE overrides reviewed settings" unless @env["XCODE_XCCONFIG_FILE"].to_s.empty?
      options = {}
      OptionParser.new do |flags|
        flags.on("--dry-run") { options[:dry] = true }
        flags.on("--output DIRECTORY") { |value| options[:output] = value }
        flags.on("--keychain FILE") { |value| options[:keychain] = value }
        flags.on("--tag TAG") { |value| options[:tag] = value }
      end.parse!(arguments)
      raise Refusal, "arguments: refused; unexpected argument" unless arguments.empty?
      tool("create-dmg", MacRelease::CREATE_DMG_MISSING)
      @version, @build = ReleaseSettings.project(@root)
      @keychain = ReleaseSettings.keychain_path(options[:keychain]) if options.key?(:keychain)
      ReleaseSettings.check_tag(options[:tag], @version) if options.key?(:tag)
      clean_source unless options[:dry]
      @head = git("rev-parse", "HEAD")
      @destination = ReleaseSettings.outside_path(options[:output] || DEFAULT_OUTPUT, File.realpath(git("rev-parse", "--show-toplevel")))
      ReleaseSettings.newer_build(@root, @build)
      @filename = "Wherever.dmg"
      dmg = File.join(@destination, @filename)
      raise Refusal, "output: refused; #{@filename} already exists" if File.exist?(dmg) || File.symlink?(dmg)
      command("project policy", "/usr/bin/ruby", File.join(@root, "scripts/check_project.rb"), show: true)
      raise Refusal, "license: refused; LICENSE missing" unless File.file?(File.join(@root, LICENSE))
      @feed = ReleaseSettings.check_info(@root)
      if options[:dry]
        say "dry run: preflight passed; signing inputs and the notary profile are checked by a real run"
        say "planned: build engine; build universal Release in #{MacRelease.kept(@env)}; check Sparkle tools; sign inside out; verify images; notarize app; staple app; create-dmg DMG; sign, notarize and staple DMG; validate 6 commands; Sparkle signature and appcast; cask; record in #{@destination}"
        return false
      end
      raise Refusal, "inputs: refused; --keychain needs SPARKLE_PRIVATE_KEY" if @keychain && !@sparkle_key
      raise Refusal, "inputs: refused; SPARKLE_PRIVATE_KEY needs --keychain" if @sparkle_key && !@keychain
      ReleaseSettings.check_sparkle_key(@sparkle_key) if @sparkle_key
      ReleaseSettings.inputs(@env)
      command("notary profile", "xcrun", "notarytool", "history", "--keychain-profile", NOTARY_PROFILE, *keychain_args, quiet: true)
      @record = { "commit" => @head, "version" => @version, "build" => @build, "architectures" => ARCHITECTURES, "notary" => {} }
      true
    rescue OptionParser::ParseError
      raise Refusal, "arguments: refused; use [--dry-run] [--output ABSOLUTE_DIRECTORY] [--keychain ABSOLUTE_FILE] [--tag vVERSION]"
    end

    def inventory(app)
      images = []
      bundles = []
      Find.find(app) do |path|
        if File.symlink?(path)
          raise Refusal, "bundle: refused; escaping symlink" unless File.realpath(path).start_with?(app + "/")
          next
        end
        if File.directory?(path)
          bundles << path if path != app && path.end_with?(".framework", ".app", ".xpc", ".appex", ".bundle")
          next
        end
        raise Refusal, "bundle: refused; nonregular entry" unless File.file?(path)
        magic = File.binread(path, 4).to_s.unpack("H*").first
        next unless %w[cafebabe bebafeca cafebabf bfbafeca feedface cefaedfe feedfacf cffaedfe].include?(magic)
        kind, = capture("file", "-b", path)
        next unless kind.include?("Mach-O")
        images << [path, kind.include?("executable")]
      end
      [images, bundles.select { |bundle| images.any? { |image, _| image.start_with?(bundle + "/") } }]
    end

    def codesign_base
      ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", @env.fetch("WHEREVER_SIGNING_IDENTITY"), *keychain_args]
    end

    def sign(app)
      FileUtils.mkdir_p(File.join(app, "Contents/Resources"))
      FileUtils.cp(File.join(@root, LICENSE), File.join(app, "Contents/Resources", LICENSE))
      images, bundles = inventory(app)
      loose = images.map(&:first).reject { |path| path.match?(%r{/([^/]+)\.(?:app|xpc|appex)/Contents/MacOS/\1\z|/([^/]+)\.framework/Versions/[^/]+/\2\z}) }
      (loose + bundles).sort_by { |path| -path.count("/") }.each { |path| command("sign nested code", *codesign_base, path, quiet: true) }
      command("sign app", *codesign_base, "--entitlements", File.join(@root, "Config/Wherever.entitlements"), app)
      say "signed inside out: #{loose.length} loose images, #{bundles.length} bundles, then the app"
      app
    end

    def sign_details(path, architecture, main)
      _out, details = command("signing metadata", "codesign", "-d", "--verbose=4", "--arch", architecture, path, quiet: true)
      unless details.match?(/^Authority=Developer ID Application: /) && details.lines.any? { |line| line.chomp == "TeamIdentifier=#{@env.fetch('WHEREVER_APPLE_TEAM_ID')}" } && details.match?(/^Timestamp=.+/)
        raise Refusal, "signing: refused; Developer ID, team or timestamp mismatch"
      end
      raise Refusal, "signing: refused; hardened runtime missing" unless details.match?(/flags=.*\bruntime\b/)
      identity = @env.fetch("WHEREVER_SIGNING_IDENTITY")
      if !identity.match?(/\A[0-9a-f]{40}\z/i) && details.lines.none? { |line| line.chomp == "Authority=#{identity}" }
        raise Refusal, "signing: refused; identity mismatch"
      end
      xml, = command("signed entitlements", "codesign", "-d", "--arch", architecture, "--entitlements", "-", "--xml", path, quiet: true)
      entitlements = xml.strip.empty? ? {} : CFPropertyList.native_types(CFPropertyList::List.new(data: xml).value)
      expected = main ? Xcodeproj::Plist.read_from_path(File.join(@root, "Config/Wherever.entitlements")) : {}
      raise Refusal, "signing: refused; unexpected entitlements" unless entitlements == expected
    end

    def verify_images(app)
      images, bundles = inventory(app)
      main = File.join(app, "Contents/MacOS/Wherever")
      raise Refusal, "bundle: refused; main executable missing" unless images.any? { |path, _| path == main }
      tool = File.join(app, "Contents/Helpers/wherever")
      raise Refusal, "bundle: refused; command-line tool missing" unless images.any? { |path, _| path == tool }
      helper = File.join(app, "Contents/Library/LoginItems/WhereverHelper.app/Contents/MacOS/WhereverHelper")
      raise Refusal, "bundle: refused; helper app missing" unless images.any? { |path, _| path == helper }
      images.sort_by { |path, _| -path.count("/") }.each do |path, _executable|
        command("image signature", "codesign", "--verify", "--strict", "--all-architectures", path, quiet: true)
        arches, = command("image architectures", "lipo", "-archs", path, quiet: true)
        MacRelease.check_architectures(arches)
        exact = path == main || path == tool || path == helper || path.include?("/WhereverKit.framework/")
        ARCHITECTURES.each do |architecture|
          load_commands, = command("deployment metadata", "otool", "-arch", architecture, "-l", path, quiet: true)
          MacRelease.check_minimum(load_commands, exact)
          sign_details(path, architecture, path == main)
        end
      end
      bundles.sort_by { |path| -path.count("/") }.each do |path|
        command("nested bundle signature", "codesign", "--verify", "--strict", "--all-architectures", path, quiet: true)
      end
      command("deep verification", "codesign", "--verify", "--deep", "--strict", "--all-architectures", app)
      @record["image_count"] = images.length
      say "images: #{images.length} verified inside out; architectures: #{ARCHITECTURES.join(' ')}; minimum macOS #{FLOOR}"
    end

    def notarize(path, label)
      @notary_started = true
      auth = ["--keychain-profile", NOTARY_PROFILE, *keychain_args]
      stdout, _stderr, code = capture("xcrun", "notarytool", "submit", path, *auth, "--wait", "--timeout", "30m", "--output-format", "json")
      result = MacRelease.notary_result(stdout, code)
      @record["notary"][label] = result
      say "notary #{label}: exit #{code}; status #{result['status']}; id #{result['id'] || 'none'}"
      return if result["accepted"]
      if result["id"]
        log, _error, log_code = capture("xcrun", "notarytool", "log", result["id"], *auth)
        result["log"] = MacRelease.notary_log(log)
        say "notary #{label} log: exit #{log_code}; issues #{result['log']['issue_count'] || 'unknown'}; retained in release-failure.json"
      end
      raise Refusal, "notary #{label}: stopped; inspect the recorded submission before any new upload"
    end

    def build
      @build_started = true
      cargo = File.join(@kept, "cargo")
      FileUtils.mkdir_p(cargo)
      command("engine", "/bin/sh", File.join(@root, "scripts/build-engine.sh"), env: { "CARGO_TARGET_DIR" => cargo }, show: true)
      clean_source
      stdout, stderr = command("build", "xcodebuild", "build", "-project", "Wherever.xcodeproj", "-scheme", "Wherever", "-configuration", "Release",
                               "-destination", "generic/platform=macOS", "-derivedDataPath", @derived, "-disableAutomaticPackageResolution",
                               "COMPILER_INDEX_STORE_ENABLE=NO", "ARCHS=#{ARCHITECTURES.join(' ')}", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO", show: true)
      diagnostics = (stdout + stderr).lines.count { |line| line.match?(DIAGNOSTIC) }
      say "build compiler diagnostics: #{diagnostics}"
      if diagnostics > 0
        FileUtils.rm_rf(File.join(@derived, "Build"))
        raise Refusal, "build: refused; compiler diagnostics"
      end
      app = File.join(@derived, "Build/Products/Release/Wherever.app")
      MacRelease.check_bundle(Xcodeproj::Plist.read_from_path(File.join(app, "Contents/Info.plist")), @version, @build)
      say "bundle version: #{@version}; build: #{@build}; minimum macOS #{FLOOR}"
      @sparkle_bin = File.join(@derived, SPARKLE_BIN)
      unless %w[sign_update generate_appcast].all? { |name| File.executable?(File.join(@sparkle_bin, name)) }
        raise Refusal, "sparkle: refused; sign_update or generate_appcast missing from the build's package checkout"
      end
      app
    end

    def create_dmg(app, staging, dmg)
      made = File.join(staging, "*.dmg")
      MacRelease::DMG_TRIES.times do |attempt|
        FileUtils.rm_f(Dir.glob(made))
        _stdout, _stderr, code = capture(*MacRelease.dmg_command(app, staging), chdir: staging)
        say "create DMG try #{attempt + 1}: exit #{code}"
        if code == 0
          files = Dir.children(staging).grep(/\.dmg\z/)
          raise Refusal, "create DMG: refused; expected one DMG, found #{files.size}" unless files.size == 1
          FileUtils.mv(File.join(staging, files.first), dmg)
          return
        end
        sleep MacRelease::DMG_PAUSE if attempt < MacRelease::DMG_TRIES - 1
      end
      FileUtils.rm_f(Dir.glob(made))
      raise Refusal, "create DMG: failed after #{MacRelease::DMG_TRIES} tries; private tool details omitted"
    end

    def package(app)
      zip = File.join(@work, "Wherever-notary.zip")
      command("notary ZIP", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip)
      notarize(zip, "app")
      command("staple app", "xcrun", "stapler", "staple", app)
      command("validate app before packaging", "xcrun", "stapler", "validate", app)
      staging = File.join(@work, "dmg")
      Dir.mkdir(staging, 0700)
      dmg = File.join(@work, @filename)
      create_dmg(app, staging, dmg)
      command("sign DMG", "codesign", "--force", "--timestamp", "--sign", @env.fetch("WHEREVER_SIGNING_IDENTITY"), *keychain_args, "-i", "#{ReleaseSettings::BUNDLE_ID}.dmg", dmg)
      _out, details = command("DMG signing metadata", "codesign", "-d", "--verbose=4", dmg)
      unless details.match?(/^Authority=Developer ID Application: /) && details.match?(/^Timestamp=.+/)
        raise Refusal, "DMG: refused; needs a timestamped Developer ID signature"
      end
      notarize(dmg, "dmg")
      command("staple DMG", "xcrun", "stapler", "staple", dmg)
      validations = [
        ["app codesign", "codesign", "--verify", "--deep", "--strict", "--all-architectures", app],
        ["app spctl", "spctl", "--assess", "--type", "execute", app],
        ["app stapler", "xcrun", "stapler", "validate", app],
        ["DMG codesign", "codesign", "--verify", "--strict", dmg],
        ["DMG stapler", "xcrun", "stapler", "validate", dmg],
        ["DMG hdiutil", "hdiutil", "verify", dmg]
      ]
      @record["validations"] = {}
      validations.each do |label, *args|
        _stdout, _stderr, code = capture(*args)
        @record["validations"][label] = code
        say "validation #{label}: exit #{code}"
      end
      raise Refusal, "validations: failed" unless @record["validations"].values.all?(&:zero?)
      dmg
    end

    def sparkle(dmg)
      key_args = @sparkle_key ? ["--ed-key-file", "-"] : KEYCHAIN_ACCOUNT
      stdout, = command("sparkle signature", File.join(@sparkle_bin, "sign_update"), *key_args, dmg, stdin: @sparkle_key.to_s)
      found = stdout.match(/sparkle:edSignature="([^"]+)"\s+length="(\d+)"/)
      raise Refusal, "sparkle: refused; sign_update printed no signature and length" unless found
      raise Refusal, "sparkle: refused; sign_update length differs from the DMG size" unless found[2].to_i == File.size(dmg)
      folder = File.join(@work, "appcast")
      Dir.mkdir(folder, 0700)
      FileUtils.cp(dmg, File.join(folder, @filename))
      appcast = File.join(@work, "appcast.xml")
      command("appcast", File.join(@sparkle_bin, "generate_appcast"), *key_args, "--download-url-prefix", format(DOWNLOAD, @version), "-o", appcast, folder, stdin: @sparkle_key.to_s)
      raise Refusal, "appcast: refused; generate_appcast wrote no appcast.xml" unless File.file?(appcast)
      text, how = MacRelease.pin_minimum(File.read(appcast))
      MacRelease.check_appcast(text, @version, @build, found[1], found[2])
      File.write(appcast, text)
      @record["sparkle"] = { "length" => found[2].to_i, "minimum_system_version" => "13.0.0 (#{how})" }
      say "appcast: one item; sparkle:version #{@build}; minimumSystemVersion 13.0.0 (#{how})"
      appcast
    end

    def cask(sha256)
      template = File.read(File.join(@root, "scripts/wherever-cask.rb.template"))
      text = MacRelease.fill_cask(template, @version, sha256, @feed)
      MacRelease.check_cask(text)
      path = File.join(@work, "wherever.rb")
      File.write(path, text)
      say "cask: stanzas in Cookbook order; depends_on macos: :ventura; ruby -c passes"
      path
    end

    def publish_outputs(app, dmg, appcast, cask)
      clean_source
      raise Refusal, "source: refused; source changed during release" unless git("rev-parse", "HEAD") == @head
      @record["filename"] = @filename
      @record["sha256"] = Digest::SHA256.file(dmg).hexdigest
      @record["license_hash"] = Digest::SHA256.file(File.join(@root, LICENSE)).hexdigest
      FileUtils.mv(dmg, File.join(@destination, @filename))
      FileUtils.mv(appcast, File.join(@destination, "appcast.xml"))
      FileUtils.mv(cask, File.join(@destination, "wherever.rb"))
      symbols = File.join(@destination, "#{File.basename(@filename, '.dmg')}.dSYMs")
      Dir[File.join(File.dirname(app), "*.dSYM")].each { |dsym| command("retain dSYM", "ditto", dsym, File.join(symbols, File.basename(dsym)), quiet: true) }
      File.write(File.join(@destination, "release-record.json"), MacRelease.sanitize(JSON.pretty_generate(@record), @env, @sparkle_key) + "\n")
      FileUtils.rm_f(File.join(@destination, "release-failure.json"))
      @finished = true
      say "validations: 6/6 zero exits"
      say "artifact: #{File.join(@destination, @filename)}; sha256: #{@record['sha256']}"
    end

    def lock
      dir = File.join(@kept, "build.lock")
      begin
        Dir.mkdir(dir)
      rescue Errno::EEXIST
        pid = File.file?(File.join(dir, "pid")) ? File.read(File.join(dir, "pid")).to_i : 0
        live = pid > 0 && capture("ps", "-o", "command=", "-p", pid.to_s).first.include?("release-macos")
        raise Refusal, "lock: refused; a release build is already live" if live
        FileUtils.rm_rf(dir)
        Dir.mkdir(dir)
      end
      @lock = dir
      File.write(File.join(dir, "pid"), Process.pid.to_s)
    end

    def run(arguments)
      key = @env.delete("SPARKLE_PRIVATE_KEY").to_s.strip
      @sparkle_key = key.empty? ? nil : key
      return 0 unless preflight(arguments)
      Dir.mkdir(@destination, 0700) unless File.directory?(@destination)
      @kept = MacRelease.kept(@env)
      FileUtils.mkdir_p(@kept)
      lock
      @work = Dir.mktmpdir("release-", @kept)
      @derived = File.join(@kept, "derived")
      app = build
      verify_images(sign(app))
      dmg = package(app)
      appcast = sparkle(dmg)
      publish_outputs(app, dmg, appcast, cask(Digest::SHA256.file(dmg).hexdigest))
      0
    rescue Refusal => error
      say error.message
      1
    rescue StandardError
      say "release: failed; private tool details omitted"
      1
    ensure
      begin
        if @work && !@finished
          File.write(File.join(@destination, "release-failure.json"), MacRelease.sanitize(JSON.pretty_generate(@record), @env, @sparkle_key) + "\n")
        end
      ensure
        FileUtils.rm_rf(@work) if @work
        FileUtils.rm_rf(@lock) if @lock
      end
      say "build: not started" unless @build_started
      say "notarization: not started" unless @notary_started
    end
  end
end

if $PROGRAM_NAME == __FILE__
  File.umask(0022)
  Signal.trap("TERM") { raise Interrupt }
  begin
    exit MacRelease::Run.new(ReleaseSettings::ROOT).run(ARGV)
  rescue Interrupt
    warn "release: interrupted; run-owned temporary files removed"
    exit 130
  end
end
