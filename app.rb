class App < Sinatra::Base
  set :public_folder, File.dirname(__FILE__) + '/public'
  set :static, true
  set :logging, true
  set :server, 'thin'
  
  JS_FILES = [
    'support/jquery.min.js',
    'support/swfobject.js',
    'support/web_socket.js',
    'support/json2.js',
    'support/underscore-min.js',
    'support/backbone-min.js',
    'support/jquery-ui.js',
    'app.js',
    'admin.js',
    'youtube.js',
    'blip.js',
    'chat.js',
  ]

  def current_user
    @current_user ||= User.find_by_id(session[:user_id]) if session[:user_id]
  end

  def login_required
    if current_user.nil?
      if request.xhr?
        status 401
      else
        session[:return_to] = request.path
        redirect '/auth'
      end

      halt
    end
  end
  
  def render_javascript(files)
    return JS_CACHE['core'] if JS_CACHE.has_key?('core')
    data = files.map{|f|File.read "#{File.dirname(__FILE__)}/javascripts/#{f}"}
    if $production
      JS_CACHE['core'] = Uglifier.compile(data.join(';'), {:squeeze => false})
      JS_CACHE['core']
    else
      data
    end
  end
  
  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  
    def partial(page, options={})
      erb page, options.merge!(:layout => false)
    end
    
    def link_to(name, href, options={})
      opts = options.keys.map { |key| "#{key}=\"#{options[key]}\"" }.join(' ')
      "<a href=\"#{escape_html(href)}\" #{opts}>#{name}</a>"
    end
    
    def get_channels
      @channels ||= Channel.all
    end
    
    def get_admin_channels
      current_user.admin ? get_channels : current_user.admin_channels
    end

    def public_tabs
      get_channels.map do |channel|
        {:id => "chan_#{channel.id}".to_sym, :class => 'room', :name => channel.permalink, :href => channel.permalink}
      end
    end

    def admin_tabs
      list = [{:id => :"admin", :class => 'admin', :name => 'Admin', :url => '/admin'}]
      if current_user.admin
        list += [{:id => :"admin_users", :class => 'admin', :name => 'Users', :url => '/admin/users'},
          {:id => :"admin_bans", :class => 'admin', :name => 'Bans', :url => '/admin/bans'},
          {:id => :"admin_channels", :class => 'admin', :name => 'Channels', :url => '/admin/channels'}]
      end
      list += get_admin_channels.map do |channel|
        {:id => :"chan_#{channel.id}", :class => 'room', :name => channel.permalink, :url => "/admin/channels/#{channel.id}"}
      end
      list
    end

    def set_tab(the_tab)
      @current_tab = the_tab
    end

    def get_tabs(list)
      current = @current_tab
      send(list).map do |tab|
        "<li id=\"tab_#{tab[:id]}\" class=\"#{tab[:class]}\"><a href=\"#{tab[:url]}\" #{current == tab[:id] ? 'class="active"' : ''}>#{escape_html tab[:name]}</a></li>"
      end.join('')
    end

    def channel_port(channel)
      if APP_CONFIG['single_server']
        # Determine from config
        APP_CONFIG['websocket_port'] || ENV['PORT']
      else
        # Determine from channel info
        channel.backend_server
      end
    end
  end

  get '/' do
    @channels = Channel.all
    
    erb :channel_index
  end
  
  # Global channel display
  get '/r/:id' do
    # Display the first channel for now
    @channel = Channel.find_by_id(params[:id])
    if @channel.nil?
      status 404
      halt
    else
      erb :channel
    end
  end
  
  get '/all.js' do
    content_type 'application/javascript'
    if $production and JS_CACHE.has_key?('last_all_time')
      last_modified(JS_CACHE['last_all_time'])
    else
      JS_CACHE['last_all_time'] = Time.now.utc
    end
    render_javascript(JS_FILES)
  end
  
  # Login

  get '/auth' do
    erb :login
  end

  post '/auth' do
    if params[:error]
      render 'error'
    else
      # get token
      @current_user = User.authenticate(params[:name], params[:password])
      if @current_user
        session[:user_id] = @current_user.id
        redirect session[:return_to] || '/'
      else
        erb :error
      end
    end
  end
  
  # Token for socket identification
  post '/auth/socket_token' do
    data = JSON.parse(request.body.read) rescue {}
    
    if current_user
      current_user.generate_auth_token!
      content_type :json
      {:auth_token => current_user.auth_token}.to_json
    else
      content_type :json
      {:name => session['name']}.to_json
    end
  end
  
  # Remember nick
  post '/auth/name' do
    data = JSON.parse(request.body.read) rescue {}
    
    content_type :json
    session[:name] = data['name'] if data['name']
    
    {}.to_json
  end
  
  # Admin panel
  
  get '/admin*' do
    login_required
    return status(401) if !current_user.admin
    
    if params[:splat].first =~ /\/?(.*)$/
      @subpath = $1[-1] == '/' ? $1[0...-1] : $1
    end
    erb :admin, :layout => :'admin_layout'
  end
  
  # Enumerate connections, videos, ban count, historical figures, etc
  get '/stats' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    {
      :subscriptions => SUBSCRIPTIONS.stats_enumerate,
      :channels => Channel.all.map(&:stats_enumerate)
    }.to_json
  end
  
  # Get users
  get '/users' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    User.all.map{|u| u.to_info(:admin => true)}.to_json
  end
  
  # Create a user
  post '/users' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    user = User.new(JSON.parse(request.body.read))
    user.updated_by = current_user
    if user.save
      status 201
      user.to_info(:admin => true).to_json
    else
      status 422
      {:error => 'InvalidAttributes', :errors => user.errors}.to_json
    end
  end
  
  # Get user info
  get '/users/:id' do
    login_required
    return status(401) if !current_user.admin and current_user.id != params[:id].to_i
    
    content_type :json
    
    user = User.find_by_id(params[:id])
    if user
      user.to_info(:admin => true).to_json
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
  
  # Update a user
  put '/users/:id' do
    login_required
    return status(401) if !current_user.admin and current_user.id != params[:id].to_i
    
    content_type :json
    user = User.find_by_id(params[:id])
    if user
      user.updated_by = current_user
      if user.update_attributes(JSON.parse(request.body.read))
        user.to_info(:admin => true).to_json
      else
        status 422
        {:error => 'InvalidAttributes', :errors => user.errors}.to_json
      end
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
  
  # Delete a user
  delete '/users/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    user = User.find_by_id(params[:id])
    if user
      if user != current_user && User.all.count > 1
        user.destroy
      else
        status 406
        {:error => 'EndOfWorld'}.to_json
      end
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
  
  # Get bans
  get '/bans' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    Ban.all.map(&:to_info).to_json
  end
  
  # Get a ban
  get '/bans/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    ban = Ban.find_by_id(params[:id])
    if ban
      ban.to_info(:admin => true).to_json
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
  
  # Update bans
  put '/bans/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    ban = Ban.find_by_id(params[:id])
    if ban
      if ban.update_attributes(JSON.parse(request.body.read))
        ban.to_info(:admin => true).to_json
      else
        status 422
        {:error => 'InvalidAttributes', :errors => ban.errors}.to_json
      end
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end

  # Create a ban
  post '/bans' do
    login_required
    return status(401) if !current_user.admin

    content_type :json

    ban = Ban.new(JSON.parse(request.body.read))
    if ban.save
      status 201
      ban.to_info(:admin => true).to_json
    else
      status 422
      {:error => 'InvalidAttributes', :errors => ban.errors}.to_json
    end
  end
  
  # Delete a ban
  delete '/bans/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    ban = Ban.find_by_id(params[:id])
    if ban
      ban.destroy
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
  
  # Create a channel
  post '/channels' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    channel = Channel.new(JSON.parse(request.body.read))
    if channel.save
      status 201
      channel.to_info(:admin => true).to_json
    else
      status 422
      {:error => 'InvalidAttributes', :errors => channel.errors}.to_json
    end
  end
  
  # List channels
  get '/channels' do
    login_required
    
    content_type :json
    Channel.all.map{|c|c.to_info(:full => true)}.to_json
  end
  
  # Get channel info
  get '/channels/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    channel = Channel.find_by_id(params[:id])
    if channel
      channel.to_info(:admin => true).to_json
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
  
  # Update channel info
  put '/channels/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    channel = Channel.find_by_id(params[:id])
    
    if channel and channel.can_admin(current_user)
      if channel.update_attributes(JSON.parse(request.body.read))
        channel.to_info(:admin => true).to_json
      else
        status 422
        {:error => 'InvalidAttributes', :errors => channel.errors}.to_json
      end
    else
      {:error => 'NotFound'}
    end
  end
  
  # Delete a channel
  delete '/channels/:id' do
    login_required
    return status(401) if !current_user.admin
    
    content_type :json
    
    channel = Channel.find_by_id(params[:id])
    if channel
      channel.destroy
    else
      status 404
      {:error => 'NotFound'}.to_json
    end
  end
end
