require './core'

use Rack::Session::Cookie, :key => APP_CONFIG['cookie_name'],
                         :path => '/',
                         :expire_after => 14400, # In seconds
                         :secret => APP_CONFIG['cookie_key']

map '/ws' do
  run WebSocketApp.new
end

map '/' do
  run App.new
end