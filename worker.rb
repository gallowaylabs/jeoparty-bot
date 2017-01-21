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
  match /^next\s*($|answer|clue)/ do |client, data, match|
    current_key = "game:#{data.channel}:current"

    # Only post a question if none is in progress
    unless $redis.exists(current_key)

      clue = get_clue(data.channel)
      if clue.nil?
        client.say(text: 'The game is over! Start a new one with `new game`', channel: data.channel)
      else
        air_date = Time.iso8601(clue['airdate']).to_i

        client.web_client.chat_postMessage(
            channel: data.channel,
            as_user: true,
            attachments: [
              {
                fallback: "#{clue['category']['title']} for $#{clue['value']}: `#{clue['question']}`",
                title: "#{clue['category']['title']} for $#{clue['value']}",
                text: "#{clue['question']}",
                ts: "#{air_date}"
              }
            ]
        )

        EM.defer do
          sleep ENV['ANSWER_TIME_SECONDS'].to_i
          # Unanswered key is used here to avoid a both a race condition with
          # current_key and an O(N) keys() operation
          unanswered_key = "unanswered:#{data.channel}:#{clue['id']}"
          if $redis.exists(unanswered_key)
            $redis.del(unanswered_key)
            $redis.del(current_key)
            client.say(text: "Time is up! The answer was \n> #{clue['answer']}", channel: data.channel)
          end
        end
      end
    end
  end

  match /^(what|whats|where|wheres|who|whos) /i do |client, data, match|
    current_key = "game:#{data.channel}:current"
    answer = $redis.get(current_key)

    unless answer.nil?
      answer = JSON.parse(answer)
      valid_attempt = $redis.set("attempt:#{data.channel}:#{data.user}:#{answer['id']}", '',
                                 ex: ENV['ANSWER_TIME_SECONDS'].to_i * 2, nx: true)
      if valid_attempt
        if is_correct?(answer['answer'], data.text)
          $redis.del(current_key)
          $redis.del("unanswered:#{data.channel}:#{answer['id']}")
          score = update_score(data.channel, data.user, answer['value'])
          client.say(text: "That is the correct answer <@#{data.user}>! Your score is now #{score}", channel: data.channel)
        else
          score = update_score(data.channel, data.user, answer['value'] * -1)
          client.say(text: "Sorry <@#{data.user}>, that is incorrect. Your score is now #{score}", channel: data.channel)
        end
      else
        client.say(text: "Only one guess per clue is allowed <@#{data.user}>!", channel: data.channel)
      end
    end
  end

  match /^show\s*(my)?\s*score/ do |client, data, match|
    score = get_score(data.channel, data.user)
    client.say(text: "<@#{data.user}>, your score is #{score}", channel: data.channel)
  end

  match /^(new|start) game/ do |client, data, match|
    game_key = "game:#{data.channel}:clues"
    clue_count = $redis.scard(game_key)

    # Only start a new game if the previous game is over or
    # hasn't started yet (e.g. if the categories sound bad)
    if clue_count.nil? || clue_count == 0 || clue_count == 30
      category_names = build_game(data.channel)

      client.say(text: "*Starting a new game!* The categories today are:\n #{category_names.join("\n")}",
                 channel: data.channel)
    else
      client.say(text: "Not yet! There are still #{clue_count} clues remaining", channel: data.channel)
    end
  end

  command 'build cache' do |client, data, match|
    build_category_cache
    client.say(text:'done', channel: data.channel)
  end
end

def is_correct?(correct, response)
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

  correct == response || similarity >= ENV['SIMILARITY_THRESHOLD'].to_f
end

# Get a clue, remove it from the pool and mark it as active in one 'transaction'
def get_clue(channel)
  game_clue_key = "game:#{channel}:clues"
  current_clue_key = "game:#{channel}:current"

  clue_key = $redis.srandmember(game_clue_key)
  unless clue_key.nil?
    clue = $redis.get(clue_key)
    parsed_clue = JSON.parse(clue)

    $redis.pipelined do
      $redis.srem(game_clue_key, clue_key)
      $redis.set(current_clue_key, clue)
      $redis.setex("unanswered:#{channel}:#{parsed_clue['id']}", ENV['ANSWER_TIME_SECONDS'].to_i + 15, '')
      # TODO: Timeout is nice so the game state isn't totally hosed if something goes wrong
    end
    parsed_clue
  end
end

def build_game(channel)
  categories = $redis.srandmember('categories', 6)
  category_names = []
  categories.each do |category|
    uri = "http://jservice.io/api/clues?category=#{category}"
    request = HTTParty.get(uri)
    response = JSON.parse(request.body)

    date_sorted = response.sort_by { |k| k['airdate']}

    # If there are >5 clues, pick a random air date to use and take all clues from that date
    selected = date_sorted.drop(rand(date_sorted.size / 5) * 5).take(5)

    selected.each do |clue|
      clue_key = "clue:#{channel}:#{clue['id']}"
      $redis.set(clue_key, clean_clue(clue).to_json)
      $redis.sadd("game:#{channel}:clues", clue_key)
    end

    category_names.append(selected.first['category']['title'])
  end
  category_names
end

def clean_old_game(channel)
  clue_keys = $redis.keys("clue:#{channel}:*")
  clue_keys.each do |key|
    $redis.del(key)
  end

  user_score_keys = $redis.keys("score:#{channel}:*:game")
  user_score_keys.each do |key|
    $redis.del(key)
  end
  $redis.del("game:#{channel}:clues")
  $redis.del("game:#{channel}:current")
end

def clean_clue(clue)
  clue['value'] = 200 if clue['value'].nil?
  clue['answer'] = Sanitize.fragment(clue['answer'])
                     .gsub(/[^\w\s]/i, '')
                     .gsub(/^(the|a|an) /i, '')
                     .gsub(/\s+(&nbsp;|&)\s+/i, ' and ')
                     .strip
                     .downcase
  clue
end

def build_category_cache
  offset = 0

  loop do
    uri = "http://jservice.io/api/categories?count=100&offset=#{offset}"
    request = HTTParty.get(uri)
    response = JSON.parse(request.body)
    response.each do |category|
      if category['clues_count'] >= 5   # Skip categories with not enough clues for a game
        # Not necessary for now
        # $redis.hmset(key, :title, category['title'], :count, category['clue_count'],
        #              :used_count, 0, :veto_count, 0)0
        $redis.sadd('categories', category['id']) # Have a category set because of the super useful SRANDMEMBER
      end
    end
    break if response.size == 0 || offset >= 25000 # For safety or something
    offset = offset + 100
  end
end

def get_random_question
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
  key = "score:#{channel}:#{user}:game"
  current_score = $redis.get(key)
  if current_score.nil?
    0
  else
    current_score.to_i
  end
end

def get_alltime_score(channel, user)
  key = "score:#{channel}:#{user}"
  current_score = $redis.get(key)
  if current_score.nil?
    0
  else
    current_score.to_i
  end
end

def update_score(channel, user, score, add = true)
  game_key = "score:#{channel}:#{user}:game"
  alltime_key = "score:#{channel}:#{user}"

  if add
    $redis.incrby(game_key, score)
    $redis.incrby(alltime_key, score)
  else
    $redis.decrby(game_key, score)
    $redis.decrby(alltime_key, score)
  end

  $redis.get(game_key)
end

EM.run do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  
  # Set up redis
  uri = URI.parse(ENV['REDIS_URL'])
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)

  bot1 = SlackRubyBot::Server.new(token: ENV['SLACK_API_TOKEN'], aliases: ['tb'])
  bot1.start_async
end
