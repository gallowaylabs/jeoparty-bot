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

class JeopartyBot < SlackRubyBot::Bot
  match /^next answer/ do |client, data, match|
    current_key = "#{data.channel}:current"

    # Only post a question if none is in progress
    unless $redis.exists(current_key)

      question = get_question
      air_date = Time.iso8601(question['airdate']).to_i

      puts client.web_client.chat_postMessage(
          channel: data.channel,
          as_user: true,
          attachments: [
            {
              fallback: "#{question['category']['title']} for $#{question['value']}: `#{question['question']}`",
              title: "#{question['category']['title']} for $#{question['value']}",
              text: "#{question['question']}",
              ts: "#{air_date}"
            }
          ]
      )

      $redis.setex(current_key, 15, question.to_json)

      EM.defer do
        sleep 10
        if $redis.exists(current_key)
          $redis.del(current_key)
          client.say(text: "Time is up! The answer was \n> #{question['answer']}", channel: data.channel)
        end
      end
    end
  end

  match /^(what|whats|where|wheres|who|whos) /i do |client, data, match|
    current_key = "#{data.channel}:current"
    answer = $redis.get(current_key)

    unless answer.nil?
      answer = JSON.parse(answer)
      if is_correct?(answer['answer'], data.text)
        $redis.del(current_key)
        score = update_score(data.channel, data.user, answer['value'])
        client.say(text: "That is the correct answer <@#{data.user}>! Your score is now #{score}", channel: data.channel)
      else
        score = update_score(data.channel, data.user, answer['value'] * -1)
        client.say(text: "Sorry <@#{data.user}>, that is incorrect. Your score is now #{score}", channel: data.channel)
      end
    end
  end

  match /^show score/ do |client, data, match|
    score = get_score(data.channel, data.user)
    client.say(text: "<@#{data.user}>, your score is #{score}", channel: data.channel)
  end

  match /^new game/ do |client, data, match|
    game_key = "#{data.channel}:game"
    if game_key.nil?
      client.say(text:'starting a new game goes here', channel: data.channel)
    end
  end
end

def is_correct?(correct, response) 
  correct = correct.gsub(/[^\w\s]/i, '')
            .gsub(/^(the|a|an) /i, '')
            .strip
            .downcase

  response = response
           .gsub(/\s+(&nbsp;|&)\s+/i, ' and ')
           .gsub(/[^\w\s]/i, '')
           .gsub(/^(what|whats|where|wheres|who|whos) /i, '')
           .gsub(/^(is|are|was|were) /, '')
           .gsub(/^(the|a|an) /i, '')
           .gsub(/\?+$/, '')
           .strip
           .downcase

  white = Text::WhiteSimilarity.new
  similarity = white.similarity(correct, response)
  puts "[LOG] Correct answer: #{correct} | User answer: #{response} | Similarity: #{similarity}"

  correct == response || similarity >= 0.6
end

def get_question
  uri = 'http://jservice.io/api/random?count=1'
  request = HTTParty.get(uri)
  puts "[LOG] #{request.body}"
  response = JSON.parse(request.body).first
  question = response['question']
  if question.nil? || question.strip == ''
    response = get_question
  end
  response['value'] = 200 if response['value'].nil?
  response['answer'] = Sanitize.fragment(response['answer'].gsub(/\s+(&nbsp;|&)\s+/i, ' and '))
  response
end

def get_score(channel, user)
  key = "score:#{channel}:#{user}"
  current_score = $redis.get(key)
  if current_score.nil?
    0
  else
    current_score.to_i
  end
end

def update_score(channel, user, score = 0)
  key = "score:#{channel}:#{user}"
  current_score = $redis.get(key)
  if current_score.nil?
    $redis.set(key, score)
    score
  else
    current_score = current_score.to_i + score
    $redis.set(key, current_score)
    current_score
  end
end

EM.run do
  bot1 = SlackRubyBot::Server.new(token: ENV['SLACK_API_TOKEN'], aliases: ['tb'])
  bot1.start_async

  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  
  # Set up redis
  uri = URI.parse(ENV['REDIS_URL'])
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end
