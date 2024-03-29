#!/usr/bin/env ruby

require "json"
require "yaml"
require "faraday"
require "faraday/multipart"
require "faraday-cookie_jar"
require "htmlentities"
require "bencode"
require "digest/sha1"
require "nokogiri"

if ARGV.empty? or ARGV.length != 3
  abort "Usage #1: ./redcurry.rb \"SOURCE_TORRENT_PL\" SOURCE TARGET\nUsage #2: ./redcurry.rb /path/to/folder/with/.torrent/files SOURCE TARGET"
end
if !ARGV[0].include?("torrentid") and ARGV[0].to_i == 0 and !File.directory?(ARGV[0])
  puts "The first argument must be either a PL to a Gazelle torrent, a torrentid, or a folder path that exists."
  abort "Usage #1: ./redcurry.rb \"SOURCE_TORRENT_PL\" SOURCE TARGET\nUsage #2: ./redcurry.rb /path/to/folder/with/.torrent/files SOURCE TARGET"
end
source = ARGV[1]
target = ARGV[2]

config = YAML::load_file('./curry.yaml')

if !config.key?(source) or !config.key?(target)
  abort "Either '#{source}' or '#{target}' is not specified in YAML. Note: the keys are case sensitive."
end

$SEEDING_FOLDER = config["seeding_folder"]
$SOURCE_COOKIE = config[source]["cookie"]
$SOURCE_API_KEY = config[source]["api_key"]
$TARGET_COOKIE = config[target]["cookie"]
$TARGET_API_KEY = config[target]["api_key"]
$SOURCE_WEB_URL = config[source]["url"]
$TARGET_WEB_URL = config[target]["url"]
$SOURCE_ANNOUNCE_HOST = config[source]["announce_host"]
$TARGET_ANNOUNCE_HOST = config[target]["announce_host"]
$SOURCE_ACRONYM = config[source]["acronym"]
$TARGET_ACRONYM = config[target]["acronym"]
if config[target]["torrent_folder"]
  $NEW_TORRENT_DIR = config[target]["torrent_folder"]
else
  $NEW_TORRENT_DIR = config["torrent_folder"]
end

# cf. https://github.com/britishtea/whatcd/
class GazelleAPI
  AuthError    = Class.new StandardError
  APIError     = Class.new StandardError
  UploadError  = Class.new StandardError

  attr_accessor :userid, :authkey, :passkey
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
      raise AuthError, connection.host
    elsif !res.success?
      raise APIError, connection.host
    end

    parsed_res = JSON.parse res.body

    if parsed_res["status"] == "failure"
      raise APIError, parsed_res["error"]
    end

    parsed_res["response"]
  end

  def set_api_key(key)
    connection.headers["Authorization"] = key
    @authenticated = true
  end

  def post(resource, parameters = {})
    unless authenticated?
      raise AuthError
    end

    res = connection.post "/ajax.php?action=#{resource}", parameters

    if res.status == 302 && res["location"] == "login.php"
      raise AuthError
    end

    if res.status == 500
      raise UploadError, "Target tracker returned HTTP 500 Internal Server Error"
    end

    parsed_res = JSON.parse res.body

    if parsed_res["status"] == "failure" || parsed_res["status"] == 400
      raise UploadError, "#{parsed_res["error"]}"
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
            raise UploadError, para.inner_text.strip
          end
        end
        raise UploadError, "Unidentified error. Trying uploading manually."
      else
        raise APIError
      end
    end

    return res.headers["location"]
  end
end

sourceAPI = GazelleAPI.new($SOURCE_WEB_URL)
if $SOURCE_COOKIE && File.exist?($SOURCE_COOKIE)
  sourceAPI.set_cookie File.read($SOURCE_COOKIE)
end
unless $SOURCE_API_KEY.nil?
  sourceAPI.set_api_key($SOURCE_API_KEY)
end
if !sourceAPI.authenticated?
  abort "ERROR: For #{$SOURCE_WEB_URL}, please specify a valid cookie file, or API key, in curry.yaml."
end

targetAPI = GazelleAPI.new($TARGET_WEB_URL)
if $TARGET_COOKIE && File.exist?($TARGET_COOKIE)
  targetAPI.set_cookie File.read($TARGET_COOKIE)
end
unless $TARGET_API_KEY.nil?
  targetAPI.set_api_key($TARGET_API_KEY)
end
if !targetAPI.authenticated?
  abort "ERROR: For #{$TARGET_WEB_URL}, please specify a valid cookie file, or API key, in curry.yaml."
end

target_index   = targetAPI.fetch :index
target_authkey = target_index["authkey"]
target_passkey = target_index["passkey"]

source_index        = sourceAPI.fetch :index
sourceAPI.userid    = source_index["id"]
sourceAPI.authkey   = source_index["authkey"]
sourceAPI.passkey   = source_index["passkey"]

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
    curries.push({source_response: source_response, folder: $NEW_TORRENT_DIR})
  end
  return curries
end

def rlstype(source_rlstype, target_short=nil)
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
  if target_short == "sugoimusic.me"
    case source_rlstype
    when 5
      return 1
    when 9
      return 2
    else
      return 0
    end
  elsif $SOURCE_ACRONYM == "OPS"
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
    abort "ERROR: Music not enclosed in a folder. Report it!"
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
  idols = []
  importance = []
  contrib_artists = []
  artist_types.each do |artistType, typeNumber|
    source_musicInfo[artistType.to_s].each do |artist|
      artists.push(HTMLEntities.new.decode(artist['name']))
      importance.push(typeNumber.to_s)
      if typeNumber.to_s != "1"
        contrib_artists.push(HTMLEntities.new.decode(artist['name']))
      else
        idols.push(HTMLEntities.new.decode(artist['name']))
      end
    end
  end

  if source_response["torrent"]["hasLog"]
    if File.directory?(source_srcdir)
      logfiles = source_response["torrent"]["fileList"].split("|||").map {|x| HTMLEntities.new.decode(x).gsub(/{{{\d+}}}/, '')}.select {|f| f.end_with? ".log"}
      logfiles = logfiles.map do |log|
        Faraday::UploadIO.new("#{source_srcdir}/#{log}", 'application/octet-stream')
      end
    else
      puts "NOTE: #{source_fpath} not found in #{$SEEDING_FOLDER}, but this torrent has log(s), so remember to manually upload them to #{$TARGET_ACRONYM}."
    end
  end
  if File.directory?(source_srcdir)
    mktorrent = ""
    mktorrents = %x[which -a mktorrent].split("\n")
    if mktorrents.empty?
      abort "ERROR: Could not find mktorrent."
    end
    mktorrents.each do |mkt_binary|
      version = %x[#{mkt_binary} -v 2>&1].scan(/mktorrent (\d).(\d)/).flatten.join(".")
      if version.to_f >= 1.1
        mktorrent = mkt_binary
      end
    end
    abort "ERROR: mktorrent 1.1+ required." if mktorrent.empty?
    %x[#{mktorrent} -p -s "#{$TARGET_ACRONYM}" -o "#{source_fpath.gsub(/\$/,"\\$")}-#{target_short}.torrent" -a "https://#{$TARGET_ANNOUNCE_HOST}/#{target_passkey}/announce" "#{source_srcdir.gsub(/\$/,"\\$")}"]
    if $?.exitstatus != 0
      puts "SKIPPING #{source_fpath}: Error creating .torrent file."
      return
    end
  else
    if $SOURCE_ACRONYM == "OPS"
      puts "WARNING: #{source_fpath}: files not found in #{$SEEDING_FOLDER}, downloading .torrent file from #{$SOURCE_ACRONYM}, which may punish users for downloading .torrent files they do not snatch."
    end
    source_torrent_url = "#{$SOURCE_WEB_URL}/torrents.php?action=download&id=#{torrent_id}&authkey=#{sourceAPI.authkey}&torrent_pass=#{sourceAPI.passkey}"
    http_conn = Faraday.new
    response = http_conn.get(source_torrent_url)
    File.open("#{$SOURCE_ACRONYM}-#{torrent_id}.torrent", 'wb') { |fp| fp.write(response.body) }
    meta = BEncode.load_file("#{$SOURCE_ACRONYM}-#{torrent_id}.torrent")
    meta["info"]["source"] = $TARGET_ACRONYM
    meta["comment"] = ""
    meta["announce"] = "https://#{$TARGET_ANNOUNCE_HOST}/#{target_passkey}/announce"
    File.open("#{$SOURCE_ACRONYM}-#{torrent_id}-to-#{$TARGET_ACRONYM}.torrent", 'wb') { |fp| fp.write(meta.bencode) }
    system("rm", "#{$SOURCE_ACRONYM}-#{torrent_id}.torrent")
  end

  if HTMLEntities.new.decode(source_response["torrent"]["description"]).include? $TARGET_ACRONYM
    puts "SKIPPING #{source_fpath}: Release description contains a reference to target tracker: #{$TARGET_ACRONYM}"
    return
  end

  print "CURRYING: #{source_fpath} | #{source_short} ===> #{target_short} ... "
  begin
    album_description = source_response["group"]["bbBody"]
    if album_description.nil?
      album_description = source_response["group"]["wikiBBcode"]
    end
    releasetype = rlstype(source_response["group"]["releaseType"])
    torrent_filename =  File.directory?(source_srcdir) ? "#{source_fpath}-#{target_short}.torrent" : "#{$SOURCE_ACRONYM}-#{torrent_id}-to-#{$TARGET_ACRONYM}.torrent"
    file_input = Faraday::UploadIO.new(torrent_filename, 'application/x-bittorrent')
    target_payload = {
      artists: artists,
      idols: idols,
      contrib_artists: contrib_artists,
      importance: importance,
      type: 0,
      title: HTMLEntities.new.decode(source_response["group"]["name"]),
      year: source_response["group"]["year"],
      auth: target_authkey,
      file_input: file_input,
      releasetype: releasetype,
      format: source_response["torrent"]["format"],
      audioformat: source_response["torrent"]["format"],
      media: source_response["torrent"]["media"],
      bitrate: source_response["torrent"]["encoding"],
      album_desc: album_description,
      release_desc: "[align=center]" + banner + "\n" + redcurry + "\n" + thanks_to_uploader + "[/align]" + "\n" + HTMLEntities.new.decode(source_response["torrent"]["description"]),
      tags: source_response["group"]["tags"].join(","),
      image: source_response["group"]["wikiImage"],
      submit: "true"
    }
    if target_short == "sugoimusic.me"
      target_payload[:type] = rlstype(releasetype, target_short="sugoimusic.me")
      target_payload[:media] = target_payload[:media] == "WEB" ? "Web" : target_payload[:media]
    end
    target_payload[:remaster] = "on"
    target_payload[:remaster_year] = source_response["torrent"]["remasterYear"].to_i == 0 ? source_response["group"]["year"] : source_response["torrent"]["remasterYear"]
    target_payload[:remasteryear] = target_payload[:remaster_year]
    target_payload[:remaster_record_label] = source_response["torrent"]["remasterRecordLabel"].to_s.empty? ? source_response["group"]["recordLabel"] : source_response["torrent"]["remasterRecordLabel"]
    target_payload[:remaster_catalogue_number] = source_response["torrent"]["remasterCatalogueNumber"].to_s.empty? ? source_response["group"]["catalogueNumber"] : source_response["torrent"]["remasterCatalogueNumber"]
    target_payload[:remaster_title] = source_response["torrent"]["remasterTitle"]
    target_payload[:remastertitle] = target_payload[:remaster_title]
    if source_response["torrent"]["scene"]
      target_payload[:scene] = "on"
    end
    if source_response["torrent"]["hasLog"]
      if File.directory?(source_srcdir)
        target_payload[:logfiles] = logfiles
      elsif $TARGET_ANNOUNCE_HOST.include?("opsfet")
        # accommodate broken behavior at OPS
        target_payload[:logfiles] = [Faraday::UploadIO.new(StringIO.new(""), 'application/octet-stream')]
      end
    end
    new_torrent_url = ""
    if !$TARGET_API_KEY.nil?
      upload_response = targetAPI.post("upload", target_payload)
      upload_response = upload_response.kind_of?(Array) ? upload_response[0] : upload_response
      torrentKey = $TARGET_ANNOUNCE_HOST.include?("opsfet") ? "torrentId" : "torrentid"
      new_torrent_url = "#{$TARGET_WEB_URL}/torrents.php?torrentid=#{upload_response[torrentKey]}"
    else
      new_torrent_url = "#{$TARGET_WEB_URL}/#{targetAPI.upload(target_payload)}"
    end
  rescue => e
    system("rm", torrent_filename)
    puts "FAILED: #{e.backtrace}\n#{e.message}"
  else
    if !folder.nil?
      # cp + rm instead of mv to accomodate certain setups, e.g. setgid folders
      system("cp", torrent_filename, folder)
      system("rm", torrent_filename)
    elsif File.directory?($NEW_TORRENT_DIR)
      system("cp", torrent_filename, $NEW_TORRENT_DIR)
      system("rm", torrent_filename)
    end
    puts "done: #{new_torrent_url}"
  end
end

torrent_id = ARGV.first.strip.split("torrentid=").last.to_i
if torrent_id == 0
  curries = process_torrents(sourceAPI, File.absolute_path(ARGV[0]))
  if curries.empty?
    abort "No .torrents to process."
  end
  curries.each do |task|
    torrent_id = task[:source_response]["torrent"]["id"]
    curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id, task[:source_response], task[:folder])
  end
else
  curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id)
end
