#!/usr/bin/env ruby

require 'json'
require "faraday"
require "faraday-cookie_jar"
require 'htmlentities'
require 'bencode'
require 'digest/sha1'
require 'pp'

# -- configuration --
# TODO: load from environment variables, and/or config file.
$SEEDING_FOLDER = "/path/to/your/seeding/folder"
$SOURCE_COOKIE = "./source_cookie.txt"
$TARGET_COOKIE = "./target_cookie.txt"
$SOURCE_WEB_URL = "https://redacted.ch"
$TARGET_WEB_URL = "https://orpheus.network"
$TARGET_ANNOUNCE_HOST = "home.opsfet.ch"
$TARGET_ANNOUNCE_FLAG = "OPS"
# -- configuration --

if ARGV.empty? or ARGV.length != 1 or ((!ARGV.first.start_with? "#{$SOURCE_WEB_URL}/torrents.php" or !ARGV.first.include? "torrentid") and !File.directory?(ARGV[0]))
  abort "Usage #1: ./red-to-ops.rb SOURCE_TORRENT_PL\nUsage #2: ./red-to-ops.rb /path/to/folder/with/.torrent/files"
end

# cf. https://github.com/britishtea/whatcd/
class GazelleAPI
  AuthError    = Class.new StandardError
  APIError     = Class.new StandardError
  UploadError  = Class.new StandardError

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
        raise UploadError
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

def process_torrents(sourceAPI, folder)
  curries = []
  torrent_files = Dir.glob("#{folder}/*.torrent")
  if torrent_files.empty?
    puts "No .torrent files found in #{folder}."
    exit(1)
  end
  torrent_files.each do |torrent|
    meta = BEncode.load_file(torrent)
    if meta.nil?
      puts "Skipping: #{torrent} => could not process file."
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

def curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id, source_response = nil, folder = nil)  
  if source_response.nil?
    source_response = sourceAPI.fetch :torrent, id: torrent_id
  end
  source_fpath    = HTMLEntities.new.decode(source_response["torrent"]["filePath"]).gsub(/\u200E+/, "")
  source_srcdir   = "#{$SEEDING_FOLDER}/#{source_fpath}"

  source_short = $SOURCE_WEB_URL.split("://").last
  target_short = $TARGET_WEB_URL.split("://").last

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

  red_to_ops = "[url=#{$SOURCE_WEB_URL}/torrents.php?torrentid=#{source_response["torrent"]["id"]}][color=#57aaca]R[/color][color=#57b5bc]E[/color][color=#56c0ae]D[/color][color=#56cba0] [/color][color=#71b0c7]⟹[/color][color=#8c94ee] [/color][color=#a990f0]O[/color][color=#c78cf2]P[/color][color=#e488f4]S[/color][/url]"
  redcurry = "[size=1][b]{[/b] Uploaded with RedCurry [b]}[/b]"
  thanks_to_uploader = "[b]{[/b] Thanks to [url=#{$SOURCE_WEB_URL}/user.php?id=#{source_response["torrent"]["userId"]}]#{source_response["torrent"]["username"]}[/url] for the [url=#{$SOURCE_WEB_URL}/torrents.php?torrentid=#{source_response["torrent"]["id"]}]original upload[/url] @ RED [b]}[/b][/size]"

  source_musicInfo = source_response["group"]["musicInfo"]
  artists = []
  importance = []
  artist_types.each do |artistType, typeNumber|
    source_musicInfo[artistType.to_s].each do |artist|
      artists.push(HTMLEntities.new.decode(artist['name']))
      importance.push(typeNumber)
    end
  end

  if source_response["torrent"]["hasLog"]
    logfiles = source_response["torrent"]["fileList"].split("|||").map {|x| HTMLEntities.new.decode(x).gsub(/{{{\d+}}}/, '')}.select {|f| f.end_with? ".log"}
    logfiles = logfiles.map do |log|
      Faraday::UploadIO.new("#{source_srcdir}/#{log}", 'application/octet-stream')
    end
  end

  %x[/usr/local/bin/mktorrent -p -s "#{$TARGET_ANNOUNCE_FLAG}" -o "#{target_short}-#{source_fpath}.torrent" -a "https://#{$TARGET_ANNOUNCE_HOST}/#{target_passkey}/announce" "#{source_srcdir.gsub(/\$/,"\\$")}"]

  if $?.exitstatus != 0
    puts "SKIPPING #{source_fpath}: Error creating .torrent file."
    return
  end

  print "Currying: #{source_fpath} | #{source_short} ===> #{target_short} ... "
  begin
    target_payload = {
      artists: artists,
      importance: importance,
      type: 0,
      title: HTMLEntities.new.decode(source_response["group"]["name"]),
      year: source_response["group"]["year"],
      auth: target_authkey,
      file_input: Faraday::UploadIO.new("#{target_short}-#{source_fpath}.torrent", 'application/x-bittorrent'),
      releasetype: source_response["group"]["releaseType"],
      format: source_response["torrent"]["format"],
      media: source_response["torrent"]["media"],
      bitrate: source_response["torrent"]["encoding"],
      album_desc: source_response["group"]["bbBody"],
      #release_desc: "[align=center]" + red_to_ops + "\n" + redcurry + "[/align]" + "\n" + HTMLEntities.new.decode(source_response["torrent"]["description"]),
      release_desc: "[align=center]" + red_to_ops + "\n" + redcurry + "\n" + thanks_to_uploader + "[/align]" + "\n" + HTMLEntities.new.decode(source_response["torrent"]["description"]),
      tags: source_response["group"]["tags"].join(","),
      image: source_response["group"]["wikiImage"],
      submit: "true"
    }
    if source_response["torrent"]["remastered"]
      target_payload[:remaster] = "on"
      target_payload[:remaster_year] = source_response["torrent"]["remasterYear"]
      target_payload[:remaster_record_label] = source_response["torrent"]["remasterRecordLabel"]
      target_payload[:remaster_catalogue_number] = source_response["torrent"]["remasterCatalogueNumber"]
      target_payload[:remaster_title] = source_response["torrent"]["remasterTitle"]
    end
    if source_response["torrent"]["scene"]
      target_payload[:scene] = "on"
    end
    if source_response["torrent"]["hasLog"]
      target_payload[:logfiles] = logfiles
    end
    targetAPI.upload(target_payload)
  rescue StandardError => e
    puts "FAILED: #{e.inspect}"
  else
    if !folder.nil?
      system("mv", "#{target_short}-#{source_fpath}.torrent", folder)
    end
    puts "done!"
  end
end

torrent_id = ARGV.first.strip.split("torrentid=").last.to_i
if torrent_id == 0
  curries = process_torrents(sourceAPI, File.absolute_path(ARGV[0]))
  if curries.empty?
    puts "No .torrents to process."
    exit(1)
  end
  curries.each do |task|
    curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id, task[:source_response], task[:folder])
  end
else
  curry(sourceAPI, targetAPI, target_authkey, target_passkey, torrent_id)
end
