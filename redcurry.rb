#!/usr/bin/env ruby

require "json"
require "yaml"
require "faraday"
require "faraday-cookie_jar"
require "htmlentities"
require "bencode"
require "digest/sha1"
require "nokogiri"

# -- configuration --
config = YAML::load_file('./curry.yaml')
$SEEDING_FOLDER = config["seeding_folder"]
$SOURCE_COOKIE = config["source"]["cookie"]
$TARGET_COOKIE = config["target"]["cookie"]
$SOURCE_WEB_URL = config["source"]["url"]
$TARGET_WEB_URL = config["target"]["url"]
$SOURCE_ANNOUNCE_HOST = config["source"]["announce_host"]
$TARGET_ANNOUNCE_HOST = config["target"]["announce_host"]
$SOURCE_ACRONYM = config["source"]["acronym"]
$TARGET_ACRONYM = config["target"]["acronym"]
$NEW_TORRENT_DIR = config["torrent_folder"]
# -- configuration --

if ARGV.empty? or ARGV.length != 1 or ((!ARGV.first.start_with? "#{$SOURCE_WEB_URL}/torrents.php" or !ARGV.first.include? "torrentid") and !File.directory?(ARGV[0]))
  abort "Usage #1: ./redcurry.rb \"SOURCE_TORRENT_PL\"\nUsage #2: ./redcurry.rb /path/to/folder/with/.torrent/files"
end

$MKTORRENT = ""
mktorrents = %x[which -a mktorrent].split("\n")
if mktorrents.empty?
  abort "ERROR: Could not find mktorrent."
end
mktorrents.each do |mktorrent|
  version = %x[#{mktorrent} -v 2>&1].scan(/mktorrent (\d).(\d)/).flatten.join(".")
  if version.to_f >= 1.1
    $MKTORRENT = mktorrent
  end
end
abort "ERROR: mktorrent 1.1+ required." if $MKTORRENT.empty?

# cf. https://github.com/britishtea/whatcd/
class GazelleAPI
  AuthError    = Class.new StandardError
  APIError     = Class.new StandardError
  UploadError  = Class.new StandardError

  attr_accessor :userid
  attr_reader :connection

  def initialize(tracker)
    @connection = Faraday.new(url: tracker) do |faraday|
      faraday.use :cookie_jar
      faraday.request :multipart
      faraday.request :url_encoded
      faraday.options.params_encoder = Faraday::FlatParamsEncoder
      faraday.adapter :net_http
    end
  end

  def set_cookie(cookie)
    connection.headers["Cookie"] = cookie
    @authenticated = true
  end

  def authenticated?
    @authenticated
  end

  def fetch(resource, parameters = {})
    unless authenticated?
      raise AuthError
    end

    res = connection.get "/ajax.php", parameters.merge(:action => resource)

    if res.status == 302 && res["location"] == "login.php"
      raise AuthError
    elsif !res.success?
      raise APIError, res.status
    end

    parsed_res = JSON.parse res.body

    if parsed_res["status"] == "failure"
      raise APIError
    end

    parsed_res["response"]
  end

  def upload(payload)
    unless authenticated?
      raise AuthError
    end

    res = connection.post "/upload.php", payload
    unless res.status == 302 && (res.headers["location"] =~ /torrents/)
      if res.status == 200
        html_response = Nokogiri::HTML(res.body)
        html_response.css('div.thin > p').each do |para|
          if para[:style].start_with? "color: red"
            raise UploadError.new para.inner_text.strip
          end
        end
        raise UploadError.new "Unidentified error. Trying uploading manually."
      else
        raise APIError
      end
    end
    
    return res.headers["location"]
  end
end

if File.exist? $SOURCE_COOKIE
  sourceAPI = GazelleAPI.new($SOURCE_WEB_URL)
  sourceAPI.set_cookie File.read($SOURCE_COOKIE)
else
  abort "ERROR: MISSING $SOURCE_COOKIE."
end

if File.exist? $TARGET_COOKIE
  targetAPI = GazelleAPI.new($TARGET_WEB_URL)
  targetAPI.set_cookie File.read($TARGET_COOKIE)
else
  abort "ERROR: MISSING $TARGET_COOKIE."
end

target_index   = targetAPI.fetch :index
target_authkey = target_index["authkey"]
target_passkey = target_index["passkey"]

sourceAPI.userid = sourceAPI.fetch(:index)["id"]

def process_torrents(sourceAPI, folder)
  curries = []
  torrent_files = Dir.glob("#{folder}/*.torrent")
  if torrent_files.empty?
    abort "No .torrent files found in #{folder}."
  end
  torrent_files.each do |torrent|
    meta = BEncode.load_file(torrent)
    if meta.nil?
      puts "Skipping: #{torrent} => could not process file."
      next
    elsif !meta["announce"].nil?
      if !meta["announce"].include?($SOURCE_ANNOUNCE_HOST)
        puts "Skipping: #{torrent} => announce host does not match configured source tracker."
        next
      end
    elsif !meta["announce-list"].nil?
      if !meta["announce-list"].flatten.any? {|a| a.include? $SOURCE_ANNOUNCE_HOST}
        puts "Skipping: #{torrent} => announce host does not match configured source tracker."
        next
      end
    else
      puts "Skipping: #{torrent} => could not parse an announce host for source tracker."
      next
    end
    infohash = Digest::SHA1.hexdigest(meta["info"].bencode)
    print "Querying source tracker for infohash (#{infohash}) ... "
    source_response = sourceAPI.fetch :torrent, :hash => infohash.upcase
    puts "found: #{HTMLEntities.new.decode(source_response["torrent"]["filePath"])}"
    curries.push({source_response: source_response, folder: folder})
  end
  return curries
end

def rlstype(source_rlstype)
  ops_to_red = {
    1 => 1,
    3 => 3,
    5 => 5,
    6 => 6,
    7 => 7,
    8 => 21,
    9 => 9,
    10 => 17,
    11 => 11,
    12 => 21,
    13 => 13,
    14 => 14,
    15 => 15,
    16 => 16,
    17 => 19,
    18 => 18,
    21 => 21
  }
  red_to_ops = {
    1 => 1,
    3 => 3,
    5 => 5,
    6 => 6,
    7 => 7,
    9 => 9,
    11 => 11,
    13 => 13,
    14 => 14,
    15 => 15,
    16 => 16,
    17 => 10,
    18 => 18,
    19 => 17,
    21 => 21
  }
  if $SOURCE_ACRONYM == "OPS"
    return ops_to_red[source_rlstype]
  elsif $TARGET_ACRONYM == "OPS"
    return red_to_ops[source_rlstype]
  else
    return source_rlstype
  end
end

def curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id, source_response = nil, folder = nil)  
  if source_response.nil?
    source_response = sourceAPI.fetch :torrent, id: torrent_id
  end
  source_fpath    = HTMLEntities.new.decode(source_response["torrent"]["filePath"]).gsub(/\u200E+/, "")
  source_srcdir   = "#{$SEEDING_FOLDER}/#{source_fpath}"

  source_short = $SOURCE_WEB_URL.split("://").last.gsub(/[^[:alpha:]\.]/, "")
  target_short = $TARGET_WEB_URL.split("://").last.gsub(/[^[:alpha:]\.]/, "")

  if source_fpath == ""
    abort "Music not enclosed in a folder. Report it!"
  end

  unless File.directory? source_srcdir
    abort "#{source_fpath} not found in #{$SEEDING_FOLDER}; nothing to curry."
  end

  artist_types = {
    artists: 1,
    with: 2,
    remixedBy: 3,
    composers: 4,
    conductor: 5,
    dj: 6,
    producer: 7
  }

  banner = "[url=#{$SOURCE_WEB_URL}/torrents.php?torrentid=#{source_response["torrent"]["id"]}][color=#57aaca]#{$SOURCE_ACRONYM[0]}[/color][color=#57b5bc]#{$SOURCE_ACRONYM[1]}[/color][color=#56c0ae]#{$SOURCE_ACRONYM[2]}[/color][color=#56cba0] [/color][color=#71b0c7]⟹[/color][color=#8c94ee] [/color][color=#a990f0]#{$TARGET_ACRONYM[0]}[/color][color=#c78cf2]#{$TARGET_ACRONYM[1]}[/color][color=#e488f4]#{$TARGET_ACRONYM[2]}[/color][/url]"
  if $SOURCE_ACRONYM.length != 3 || $TARGET_ACRONYM.length != 3
    banner = "[url=#{$SOURCE_WEB_URL}/torrents.php?torrentid=#{source_response["torrent"]["id"]}]#{$SOURCE_ACRONYM} [b]⟹[/b] #{$TARGET_ACRONYM}[/url]"
  end
  redcurry = "[size=1][b]{[/b] Uploaded with RedCurry [b]}[/b]"
  uploader = source_response["torrent"]["userId"] == sourceAPI.userid ? "my" : source_response["torrent"]["username"]
  thanks_to_uploader = "[b]{[/b] cross-post of [url=#{$SOURCE_WEB_URL}/user.php?id=#{source_response["torrent"]["userId"]}]#{uploader}[/url]#{uploader == "my" ? "" : "'s"} #{$SOURCE_ACRONYM} [url=#{$SOURCE_WEB_URL}/torrents.php?torrentid=#{source_response["torrent"]["id"]}]upload[/url] [b]}[/b][/size]"

  source_musicInfo = source_response["group"]["musicInfo"]
  artists = []
  importance = []
  artist_types.each do |artistType, typeNumber|
    source_musicInfo[artistType.to_s].each do |artist|
      artists.push(HTMLEntities.new.decode(artist['name']))
      importance.push(typeNumber.to_s)
    end
  end

  if source_response["torrent"]["hasLog"]
    logfiles = source_response["torrent"]["fileList"].split("|||").map {|x| HTMLEntities.new.decode(x).gsub(/{{{\d+}}}/, '')}.select {|f| f.end_with? ".log"}
    logfiles = logfiles.map do |log|
      Faraday::UploadIO.new("#{source_srcdir}/#{log}", 'application/octet-stream')
    end
  end

  %x[#{$MKTORRENT} -p -s "#{$TARGET_ACRONYM}" -o "#{source_fpath.gsub(/\$/,"\\$")}-#{target_short}.torrent" -a "https://#{$TARGET_ANNOUNCE_HOST}/#{target_passkey}/announce" "#{source_srcdir.gsub(/\$/,"\\$")}"]

  if $?.exitstatus != 0
    puts "SKIPPING #{source_fpath}: Error creating .torrent file."
    return
  end

  print "Currying: #{source_fpath} | #{source_short} ===> #{target_short} ... "
  begin
    bbcode_description = "bbBody"
    if $SOURCE_ACRONYM == "OPS"
      bbcode_description = "wikiBBcode"
    end
    releasetype = rlstype(source_response["group"]["releaseType"])
    target_payload = {
      artists: artists,
      importance: importance,
      type: 0,
      title: HTMLEntities.new.decode(source_response["group"]["name"]),
      year: source_response["group"]["year"],
      auth: target_authkey,
      file_input: Faraday::UploadIO.new("#{source_fpath}-#{target_short}.torrent", 'application/x-bittorrent'),
      releasetype: releasetype,
      format: source_response["torrent"]["format"],
      media: source_response["torrent"]["media"],
      bitrate: source_response["torrent"]["encoding"],
      album_desc: source_response["group"][bbcode_description],
      release_desc: "[align=center]" + banner + "\n" + redcurry + "\n" + thanks_to_uploader + "[/align]" + "\n" + HTMLEntities.new.decode(source_response["torrent"]["description"]),
      tags: source_response["group"]["tags"].join(","),
      image: source_response["group"]["wikiImage"],
      submit: "true"
    }
    target_payload[:remaster] = "on"
    target_payload[:remaster_year] = source_response["torrent"]["remasterYear"] == 0 ? source_response["group"]["year"] : source_response["torrent"]["remasterYear"]
    target_payload[:remaster_record_label] = source_response["torrent"]["remasterRecordLabel"].empty? ? source_response["group"]["recordLabel"] : source_response["torrent"]["remasterRecordLabel"]
    target_payload[:remaster_catalogue_number] = source_response["torrent"]["remasterCatalogueNumber"].empty? ? source_response["group"]["catalogueNumber"] : source_response["torrent"]["remasterCatalogueNumber"]
    target_payload[:remaster_title] = source_response["torrent"]["remasterTitle"]
    if source_response["torrent"]["scene"]
      target_payload[:scene] = "on"
    end
    if source_response["torrent"]["hasLog"]
      target_payload[:logfiles] = logfiles
    end
    new_group = targetAPI.upload(target_payload)
  rescue => e
    system("rm", "#{source_fpath}-#{target_short}.torrent")
    puts "FAILED: #{e.message}"
  else
    if !folder.nil?
      system("mv", "#{source_fpath}-#{target_short}.torrent", folder)
    elsif File.directory?($NEW_TORRENT_DIR)
      system("mv", "#{source_fpath}-#{target_short}.torrent", $NEW_TORRENT_DIR)
    end
    puts "done: #{$TARGET_WEB_URL}/#{new_group}"
  end
end

torrent_id = ARGV.first.strip.split("torrentid=").last.to_i
if torrent_id == 0
  curries = process_torrents(sourceAPI, File.absolute_path(ARGV[0]))
  if curries.empty?
    abort "No .torrents to process."
  end
  curries.each do |task|
    curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id, task[:source_response], task[:folder])
  end
else
  curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id)
end
