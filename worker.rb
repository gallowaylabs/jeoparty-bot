require 'slack-ruby-bot'
require 'eventmachine'

class PongBot < SlackRubyBot::Bot
  command 'ping' do |client, data, match|
    client.say(text: 'pong', channel: data.channel)
    EM.defer do
      sleep 10
      client.say(text: 'later', channel: data.channel)
    end
  end
end

EM.run do
  bot1 = SlackRubyBot::Server.new(token: ENV['SLACK_API_TOKEN'], aliases: ['tb'])
  bot1.start_async
end
	
#PongBot.run
