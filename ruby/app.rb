require 'digest/sha1'
require 'net/http'
require 'mysql2'
require 'mysql2-cs-bind'
require 'connection_pool'
require 'hiredis'
require 'redis/connection/hiredis'
require 'redis'
require 'oj'
require 'sinatra/base'

$redis = ConnectionPool.new(size: 64, timeout: 3) do
  Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379"))
end

WEB_SERVERS = ENV.fetch("SERVERS", "localhost:5000").split(',')

Mysql2::Client.new(
  host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
  port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
  username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
  password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
  database: 'isubata',
  encoding: 'utf8mb4'
).tap { |db_client| db_client.query('SET SESSION sql_mode=\'TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY\'') }

$db = ConnectionPool::Wrapper.new(size: 64, timeout: 3) do
  Mysql2::Client.new(
    host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
    port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
    username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
    password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
    database: 'isubata',
    encoding: 'utf8mb4'
  )
end

class App < Sinatra::Base
  PUBLIC_FOLDER = File.expand_path('../../public', __FILE__)
  IMAGES_FOLDER = File.join(File.expand_path('../../public', __FILE__), "images")

  configure do
    set :session_secret, 'tonymoris'
    set :public_folder, PUBLIC_FOLDER
    set :avatar_max_size, 1 * 1024 * 1024

    enable :sessions
    # enable :logging
  end

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  helpers do
    def user
      return @_user unless @_user.nil?

      user_id = session[:user_id]
      return nil if user_id.nil?

      @_user = db_get_user(user_id)
      if @_user.nil?
        params[:user_id] = nil
        return nil
      end

      @_user
    end
  end

  get '/initialize' do
    db.query("DELETE FROM user WHERE id > 1000")
    db.query("DELETE FROM image WHERE id > 1001")
    db.query("DELETE FROM channel WHERE id > 10")
    db.query("DELETE FROM message WHERE id > 10000")
    db.query("DELETE FROM haveread")
    $redis.with { |redis| redis.flushall } # clear redis

    # initiali cache
    db.query('SELECT id, name, description FROM channel ORDER BY id').each do |ch|
      $redis.with do |redis|
        redis.hset("channels", ch["id"].to_s, Oj.dump(ch))
      end
    end

    204
  end

  get '/' do
    if session.has_key?(:user_id)
      return redirect '/channel/1', 303
    end
    erb :index
  end

  get '/channel/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i
    @channels, @description = get_channel_list_info(@channel_id)
    erb :channel
  end

  get '/register' do
    erb :register
  end

  post '/register' do
    name = params[:name]
    pw = params[:password]
    if name.nil? || name.empty? || pw.nil? || pw.empty?
      return 400
    end
    begin
      user_id = register(name, pw)
    rescue Mysql2::Error => e
      return 409 if e.error_number == 1062
      raise e
    end
    session[:user_id] = user_id
    redirect '/', 303
  end

  get '/login' do
    erb :login
  end

  post '/login' do
    name = params[:name]
    row = db.xquery('SELECT * FROM user WHERE name = ?', name).first
    if row.nil? || row['password'] != Digest::SHA1.hexdigest(row['salt'] + params[:password])
      return 403
    end
    session[:user_id] = row['id']
    redirect '/', 303
  end

  get '/logout' do
    session[:user_id] = nil
    redirect '/', 303
  end

  post '/message' do
    user_id = session[:user_id]
    message = params[:message]
    channel_id = params[:channel_id]
    if user_id.nil? || message.nil? || channel_id.nil? || user.nil?
      return 403
    end
    db_add_message(channel_id.to_i, user_id, message)
    204
  end

  get '/message' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    channel_id = params[:channel_id].to_i
    last_message_id = params[:last_message_id].to_i
    rows = db.xquery('SELECT * FROM message WHERE id > ? AND channel_id = ? ORDER BY id DESC LIMIT 100', last_message_id, channel_id).to_a
    response = []
    rows.each do |row|
      r = {}
      r['id'] = row['id']
      r['user'] = db.xquery('SELECT name, display_name, avatar_icon FROM user WHERE id = ?', row['user_id']).first
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      response << r
    end
    response.reverse!

    max_message_id = rows.empty? ? 0 : rows.map { |row| row['id'] }.max
    $redis.with do |redis|
      redis.hset("haveread:#{user_id}", channel_id.to_s, max_message_id.to_s)
    end

    content_type :json
    response.to_json
  end

  get '/fetch' do
    user_id = session[:user_id]
    if user_id.nil?
      return 403
    end

    sleep 1.0

    channel_ids = get_all_channels_from_redis.keys.map(&:to_i)

    havereads = $redis.with do |redis|
      redis.hgetall("haveread:#{user_id}")
    end

    res = []
    channel_ids.each do |channel_id|
      max_message_id = havereads[channel_id.to_s]&.to_i
      r = {}
      r['channel_id'] = channel_id
      r['unread'] = if max_message_id.nil?
        db.xquery('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?', channel_id).first['cnt']
      else
        db.xquery('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ? AND ? < id', channel_id, max_message_id).first['cnt']
      end
      res << r
    end

    content_type :json
    res.to_json
  end

  get '/history/:channel_id' do
    if user.nil?
      return redirect '/login', 303
    end

    @channel_id = params[:channel_id].to_i

    @page = params[:page]
    if @page.nil?
      @page = '1'
    end
    if @page !~ /\A\d+\Z/ || @page == '0'
      return 400
    end
    @page = @page.to_i

    n = 20
    rows = db.xquery("SELECT * FROM message WHERE channel_id = ? ORDER BY id DESC LIMIT #{n} OFFSET #{(@page - 1) * n}", @channel_id).to_a
    @messages = []
    rows.each do |row|
      r = {}
      r['id'] = row['id']
      r['user'] = db.xquery('SELECT name, display_name, avatar_icon FROM user WHERE id = ?', row['user_id']).first
      r['date'] = row['created_at'].strftime("%Y/%m/%d %H:%M:%S")
      r['content'] = row['content']
      @messages << r
    end
    @messages.reverse!

    cnt = db.xquery('SELECT COUNT(*) as cnt FROM message WHERE channel_id = ?', @channel_id).first['cnt'].to_f
    @max_page = cnt == 0 ? 1 :(cnt / n).ceil

    return 400 if @page > @max_page

    @channels, @description = get_channel_list_info(@channel_id)
    erb :history
  end

  get '/profile/:user_name' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info

    user_name = params[:user_name]
    @user = db.xquery('SELECT * FROM user WHERE name = ?', user_name).first

    if @user.nil?
      return 404
    end

    @self_profile = user['id'] == @user['id']
    erb :profile
  end

  get '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    @channels, = get_channel_list_info
    erb :add_channel
  end

  post '/add_channel' do
    if user.nil?
      return redirect '/login', 303
    end

    name = params[:name]
    description = params[:description]
    if name.nil? || description.nil?
      return 400
    end
    db.xquery('INSERT INTO channel (name, description, updated_at, created_at) VALUES (?, ?, NOW(), NOW())', name, description)
    channel_id = db.last_id
    $redis.with do |redis|
      redis.hset("channels", channel_id.to_s, Oj.dump({"id" => channel_id, "name" => name, "description" => description}))
    end
    redirect "/channel/#{channel_id}", 303
  end

  def upload_icon(server, path, data)
    host, port = server.split(':')
    port = (port || 80).to_i
    p(host: host, port: port, path: path, data_size: data.size)
    Net::HTTP.start(host, port) do |http|
      http.put(path, data, {'Content-Type' => 'application/octet-stream'})
    end
  end

  post '/profile' do
    if user.nil?
      return redirect '/login', 303
    end

    if user.nil?
      return 403
    end

    display_name = params[:display_name]
    avatar_name = nil
    avatar_data = nil

    file = params[:avatar_icon]
    unless file.nil?
      filename = file[:filename]
      if !filename.nil? && !filename.empty?
        ext = filename.include?('.') ? File.extname(filename) : ''
        unless ['.jpg', '.jpeg', '.png', '.gif'].include?(ext)
          return 400
        end

        if settings.avatar_max_size < file[:tempfile].size
          return 400
        end

        data = file[:tempfile].read
        digest = Digest::SHA1.hexdigest(data)

        avatar_name = digest + ext
        avatar_data = data
      end
    end

    if avatar_name && avatar_data
      path = "/icons/#{avatar_name}"
      WEB_SERVERS.each do |server|
        upload_icon(server, path, avatar_data)
      end
      db.xquery('UPDATE user SET avatar_icon = ? WHERE id = ?', avatar_name, user['id'])
    end

    if !display_name.nil? || !display_name.empty?
      db.xquery('UPDATE user SET display_name = ? WHERE id = ?', display_name, user['id'])
    end

    redirect '/', 303
  end

  put '/icons/:file_name' do
    file_name = params[:file_name]
    content_body = request.body.read
    File.open(File.join(IMAGES_FOLDER, file_name), 'w') do |f|
      f.write content_body
    end
    200
  end

  get '/icons/:file_name' do
    file_name = params[:file_name]
    path = File.join(IMAGES_FOLDER, file_name)
    if File.exist?(path)
      return File.open(path){|f| f.read }
    end
    404
  end

  private

  def db
    $db
  end

  def db_get_user(user_id)
    user = db.xquery('SELECT * FROM user WHERE id = ?', user_id).first
    user
  end

  def db_add_message(channel_id, user_id, content)
    messages = db.xquery('INSERT INTO message (channel_id, user_id, content, created_at) VALUES (?, ?, ?, NOW())', channel_id, user_id, content)
    messages
  end

  def random_string(n)
    Array.new(20).map { (('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a).sample }.join
  end

  def register(user, password)
    salt = random_string(20)
    pass_digest = Digest::SHA1.hexdigest(salt + password)
    db.xquery('INSERT INTO user (name, salt, password, display_name, avatar_icon, created_at) VALUES (?, ?, ?, ?, ?, NOW())', user, salt, pass_digest, user, 'default.png')
    row = db.query('SELECT LAST_INSERT_ID() AS last_insert_id').first
    row['last_insert_id']
  end

  def get_channel_list_info(focus_channel_id = nil)
    channels = get_all_channels_from_redis.values.sort_by { |ch| ch["id"] }
    description = ''
    if focus_channel_id
      focused = get_channel_from_redis(focus_channel_id)
      description = focused['description']
    end
    [channels, description]
  end

  # @return Hash<id String>, <channel Hash>>
  def get_all_channels_from_redis
    $redis.with do |redis|
      redis.hgetall("channels").transform_values { |v| Oj.load(v) }
    end
  end

  def get_channel_from_redis(id)
    $redis.with do |redis|
      Oj.load(redis.hget("channels", id.to_s))
    end
  end

  def ext2mime(ext)
    if ['.jpg', '.jpeg'].include?(ext)
      return 'image/jpeg'
    end
    if ext == '.png'
      return 'image/png'
    end
    if ext == '.gif'
      return 'image/gif'
    end
    ''
  end
end
