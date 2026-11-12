#!/usr/bin/ruby

require "json"
require "open3"
require "zlib"

module Icons
  PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b
  APP_SLOTS = [16, 32, 128, 256, 512].product([1, 2]).map { |points, scale| ["#{points}x#{points}", "#{scale}x", points * scale] }.freeze
  MENU_BAR_POINTS = 18
  MENU_BAR = { "1x" => ["MenuBarIcon.png", MENU_BAR_POINTS], "2x" => ["MenuBarIcon@2x.png", MENU_BAR_POINTS * 2] }.freeze

  def self.paeth(a, b, c)
    p = a + b - c
    pa, pb, pc = (p - a).abs, (p - b).abs, (p - c).abs
    return a if pa <= pb && pa <= pc
    pb <= pc ? b : c
  end

  def self.png(path)
    data = File.binread(path)
    raise "#{path}: not a PNG" unless data.byteslice(0, 8) == PNG_SIGNATURE
    header = nil
    idat = "".b
    position = 8
    while position < data.bytesize
      length, type = data.byteslice(position, 8).unpack("Na4")
      chunk = data.byteslice(position + 8, length)
      header = chunk if type == "IHDR"
      idat << chunk if type == "IDAT"
      position += 12 + length
    end
    width, height, depth, color, _, _, interlace = header.unpack("N2C5")
    raise "#{path}: expected 8-bit RGBA, not interlaced" unless depth == 8 && color == 6 && interlace == 0
    stride = width * 4
    raw = Zlib::Inflate.inflate(idat)
    raise "#{path}: truncated" unless raw.bytesize == height * (stride + 1)
    previous = Array.new(stride, 0)
    rows = Array.new(height) do |y|
      filter = raw.getbyte(y * (stride + 1))
      row = raw.byteslice(y * (stride + 1) + 1, stride).bytes
      row.each_index do |i|
        left = i >= 4 ? row[i - 4] : 0
        up = previous[i]
        upleft = i >= 4 ? previous[i - 4] : 0
        row[i] = (row[i] + [0, left, up, (left + up) / 2, paeth(left, up, upleft)].fetch(filter)) & 255
      end
      previous = row
    end
    [width, height, rows]
  end

  def self.bounds(rows)
    xs = rows.flat_map { |row| (0...row.length / 4).select { |x| row[x * 4 + 3] > 0 } }
    ys = rows.each_index.select { |y| (0...rows[y].length / 4).any? { |x| rows[y][x * 4 + 3] > 0 } }
    xs.empty? ? nil : [xs.min..xs.max, ys.min..ys.max]
  end

  def self.json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def self.files(folder, named, failures, label)
    held = Dir.children(folder).reject { |name| name == "Contents.json" || name.start_with?(".") }
    (held - named).each { |name| failures << "#{label}: #{name} is not named by Contents.json" }
    (named - held).each { |name| failures << "#{label}: Contents.json names #{name}, which is missing" }
    held & named
  end

  def self.app_icon(set, failures)
    contents = json(File.join(set, "Contents.json"))
    images = contents.is_a?(Hash) && contents["images"]
    return failures << "AppIcon: Contents.json missing or has no images" unless images.is_a?(Array)
    slots = images.map { |entry| [entry["size"], entry["scale"]] }
    expected = APP_SLOTS.map { |size, scale, _| [size, scale] }
    failures << "AppIcon: #{images.length} entries, expected #{APP_SLOTS.length} with slots #{expected.map { |s| s.join('@') }.join(', ')}" unless slots.sort == expected.sort
    failures << "AppIcon: every entry must be idiom mac" unless images.all? { |entry| entry["idiom"] == "mac" }
    named = images.map { |entry| entry["filename"] }
    failures << "AppIcon: entries must name distinct files" unless named.all? { |name| name.is_a?(String) } && named.uniq.length == named.length
    present = files(set, named.grep(String), failures, "AppIcon")
    paths = present.map { |name| File.join(set, name) }
    return if paths.empty?
    out, err, status = Open3.capture3("/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", *paths)
    return failures << "AppIcon: sips cannot decode every file: #{err.strip}" unless status.success?
    decoded = out.split(/^(?=\S)/).to_h { |block| [File.basename(block.lines.first.strip), block] }
    images.each do |entry|
      name = entry["filename"]
      next unless present.include?(name)
      want = APP_SLOTS.find { |size, scale, _| [size, scale] == [entry["size"], entry["scale"]] }&.last
      block = decoded[name].to_s
      got = %w[pixelWidth pixelHeight].map { |key| block[/#{key}: (\d+)/, 1].to_i }
      failures << "AppIcon: #{name} is #{got.join(' by ')} px, expected #{want} by #{want}" unless want && got == [want, want]
      failures << "AppIcon: #{name} has no alpha" unless block.include?("hasAlpha: yes")
      next unless got == [want, want]
      _, _, rows = png(File.join(set, name))
      failures << "AppIcon: #{name} center pixel is not opaque" unless rows[want / 2][want / 2 * 4 + 3] == 255
      next unless name == "icon_512x512_2x.png"
      tile = bounds(rows)
      failures << "AppIcon: #{name} tile is #{tile ? tile.map { |r| "#{r.min}...#{r.max}" }.join(' by ') : 'empty'}, expected 824 px inside 100...923 on both axes" unless tile && tile.all? { |r| r.min >= 100 && r.max <= 923 } && tile.map(&:size).max == 824
    end
  rescue RuntimeError, Zlib::Error => error
    failures << "AppIcon: #{error.message}"
  end

  def self.menu_bar(set, failures)
    contents = json(File.join(set, "Contents.json"))
    return failures << "MenuBarIcon: Contents.json missing or malformed" unless contents.is_a?(Hash)
    failures << "MenuBarIcon: template-rendering-intent is not template" unless contents.dig("properties", "template-rendering-intent") == "template"
    images = contents["images"].is_a?(Array) ? contents["images"] : []
    failures << "MenuBarIcon: entries are #{images.map { |e| [e['scale'], e['filename']] }}, expected #{MENU_BAR.map { |scale, (name, _)| [scale, name] }}" unless images.map { |e| [e["scale"], e["filename"]] }.sort == MENU_BAR.map { |scale, (name, _)| [scale, name] }.sort
    files(set, images.map { |entry| entry["filename"] }.grep(String), failures, "MenuBarIcon")
    MENU_BAR.each_value do |name, pixels|
      path = File.join(set, name)
      next failures << "MenuBarIcon: #{name} is missing" unless File.file?(path)
      width, height, rows = png(path)
      next failures << "MenuBarIcon: #{name} is #{width} by #{height} px, expected #{pixels} by #{pixels}" unless width == pixels && height == pixels
      rows.each_with_index do |row, y|
        row.each_slice(4).with_index do |(r, g, b, a), x|
          failures << "MenuBarIcon: #{name} pixel #{x},#{y} is not black" if a > 0 && (r | g | b) != 0
        end
      end
      [[0, 0], [width - 1, 0], [0, height - 1], [width - 1, height - 1]].each do |x, y|
        failures << "MenuBarIcon: #{name} corner #{x},#{y} is not transparent" unless rows[y][x * 4 + 3] == 0
      end
      inked = (0...height).flat_map { |y| (0...width).select { |x| rows[y][x * 4 + 3] > 0 }.map { |x| [x, y] } }
      next failures << "MenuBarIcon: #{name} is fully transparent" if inked.empty?
    end
  rescue RuntimeError, Zlib::Error => error
    failures << "MenuBarIcon: #{error.message}"
  end

  def self.check(catalog)
    failures = []
    return ["catalog #{catalog} is not a real folder"] if File.symlink?(catalog) || !File.directory?(catalog)
    %w[AppIcon.appiconset MenuBarIcon.imageset].each do |name|
      path = File.join(catalog, name)
      return failures + ["#{name} is not a real folder"] if File.symlink?(path) || !File.directory?(path)
      Dir.glob(File.join(path, "*")).each { |entry| failures << "#{name}/#{File.basename(entry)} is not a regular file" unless File.lstat(entry).file? }
    end
    failures << "catalog Contents.json missing" unless json(File.join(catalog, "Contents.json")).is_a?(Hash)
    return failures unless failures.empty?
    app_icon(File.join(catalog, "AppIcon.appiconset"), failures)
    menu_bar(File.join(catalog, "MenuBarIcon.imageset"), failures)
    failures
  end
end

if $PROGRAM_NAME == __FILE__
  catalog = ARGV.first || File.expand_path("../Wherever/Resources/Assets.xcassets", __dir__)
  failures = Icons.check(catalog)
  if failures.empty?
    puts "icons: #{Icons::APP_SLOTS.length} app renditions, #{Icons::MENU_BAR.length} menu bar files, template"
  else
    failures.each { |failure| warn "icons: #{failure}" }
    exit 1
  end
end
