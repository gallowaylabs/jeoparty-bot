require 'slack-ruby-bot'
require 'eventmachine'
require 'json'
require 'httparty'
require 'sanitize'
require 'time'
require 'dotenv'
require 'redis'
require 'text'

SlackRubyBot::Client.logger.level = Logger::WARN

class PongBot < SlackRubyBot::Bot
  command 'ping' do |client, data, match|
    client.say(text: 'pong', channel: data.channel)
    EM.defer do
      sleep 10
      client.say(text: 'later', channel: data.channel)
    end
  end

  match /^next answer/ do |client, data, match|
    current_key = "#{data.channel}:current:answer"

    # Only post a question if none is in progress
    if !$redis.exists(current_key)

      question = get_question
      airdate = Time.iso8601(question["airdate"]).to_i

      client.web_client.chat_postMessage(
          channel: data.channel,
          as_user: true,
          attachments: [
            {
              fallback: "#{question["category"]["title"]} ($ #{question["value"]}): #{question["question"]}",
              title: "#{question["category"]["title"]} for $#{question["value"]}",
              text: "#{question["question"]}",
              ts: "#{airdate}"
            }
          ]
      )

      $redis.setex(current_key, 15, question["answer"])

      EM.defer do
        sleep 10
        if $redis.exists(current_key)
          $redis.del(current_key)
          client.say(text: "Time is up! The answer was \n> #{question["answer"]}", channel: data.channel)
        end
      end
    end
  end

  match /^(what|whats|where|wheres|who|whos) /i do |client, data, match|

    current_key = "#{data.channel}:current:answer"
    answer = $redis.get(current_key)
    if !answer.nil?
      if is_correct?(answer, data.text)
        $redis.del(current_key)
        client.say(text: "You did it!", channel: data.channel)
      else
        client.say(text: "Nope :(", channel: data.channel)
      end
    end
  end
end

def is_correct?(correct, response) 
  correct = correct.gsub(/[^\w\s]/i, "")
            .gsub(/^(the|a|an) /i, "")
            .strip
            .downcase

  response = response
           .gsub(/\s+(&nbsp;|&)\s+/i, " and ")
           .gsub(/[^\w\s]/i, "")
           .gsub(/^(what|whats|where|wheres|who|whos) /i, "")
           .gsub(/^(is|are|was|were) /, "")
           .gsub(/^(the|a|an) /i, "")
           .gsub(/\?+$/, "")
           .strip
           .downcase

  white = Text::WhiteSimilarity.new
  similarity = white.similarity(correct, response)
  puts "[LOG] Correct answer: #{correct} | User answer: #{response} | Similarity: #{similarity}"

  correct == response || similarity >= 0.6
end

def get_question
  uri = "http://jservice.io/api/random?count=1"
  request = HTTParty.get(uri)
  puts "[LOG] #{request.body}"
  response = JSON.parse(request.body).first
  question = response["question"]
  if question.nil? || question.strip == "" 
    response = get_question
  end
  response["value"] = 200 if response["value"].nil?
  response["answer"] = Sanitize.fragment(response["answer"].gsub(/\s+(&nbsp;|&)\s+/i, " and "))
  response
end

EM.run do
  bot1 = SlackRubyBot::Server.new(token: ENV['SLACK_API_TOKEN'], aliases: ['tb'])
  bot1.start_async

  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  
  # Set up redis
  uri = URI.parse(ENV["REDIS_URL"])
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)

end
	
#PongBot.run
