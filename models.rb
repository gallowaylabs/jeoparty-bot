module Mapper
  def self.redis
    @redis
  end
  def self.redis=(redis)
    @redis = redis
  end

  class Model
    def self.redis=(redis)
      @redis = redis
    end

    def self.redis
      defined?(@redis) ? @redis : Mapper.redis
    end
  end
end

class Game < Mapper::Model
  attr_accessor :channel, :redis

  def Game.in(channel)
    game = Game.new
    game.channel = channel
    game.redis = Mapper.redis
    game
  end

  # Start a new game
  def new_game
    cleanup # Clean old game data/scores

    category_names = []
    # Pick 6 random categories
    categories = @redis.srandmember('categories', 6)
    categories.each do |category|
      uri = "http://jservice.io/api/clues?category=#{category}"
      request = HTTParty.get(uri)
      response = JSON.parse(request.body)

      date_sorted = response.sort_by { |k| k['airdate']}

      # If there are >5 clues, pick a random air date to use and take all clues from that date
      selected = date_sorted.drop(rand(date_sorted.size / 5) * 5).take(5)

      selected.each do |clue|
        clue = _clean_clue(clue)
        unless clue.nil?  # Don't add degenerate clues
          clue_key = "game_clue:#{channel}:#{clue['id']}"
          @redis.set(clue_key, clue.to_json)
          @redis.sadd("game:#{channel}:clues", clue_key)
        end
      end

      category_names.append(selected.first['category']['title'])
    end
    category_names
  end

  # Clean up artifacts of the previous game in this channel
  def cleanup
    clue_keys = @redis.keys("game_clue:#{channel}:*")
    clue_keys.each do |key|
      @redis.del(key)
    end

    user_score_keys = @redis.keys("game_score:#{channel}:*")
    user_score_keys.each do |key|
      @redis.del(key)
    end
    @redis.del("game:#{channel}:clues")
    @redis.del("game:#{channel}:current")
  end

  # Get clue from the current game by ID
  def get_clue(clue_id)
    clue = @redis.get("game_clue:#{channel}:#{clue_id}")
    unless clue.nil?
      JSON.parse(clue)
    end
  end

  # Get the current clue in this game
  def current_clue
    clue = @redis.get("game:#{channel}:current")

    unless clue.nil?
      JSON.parse(clue)
    end
  end

  # Get a clue, remove it from the pool and mark it as active in one 'transaction'
  def next_clue
    game_clue_key = "game:#{channel}:clues"
    current_clue_key = "game:#{channel}:current"

    clue_key = @redis.srandmember(game_clue_key)
    unless clue_key.nil?
      clue = @redis.get(clue_key)
      parsed_clue = JSON.parse(clue)

      @redis.pipelined do
        @redis.srem(game_clue_key, clue_key)
        @redis.set(current_clue_key, clue)
        @redis.setex("unanswered:#{channel}:#{parsed_clue['id']}", ENV['ANSWER_TIME_SECONDS'].to_i + 15, '')
      end
      parsed_clue
    end
  end

  # Mark clue as answered
  def clue_answered
    @redis.del("game:#{channel}:current")
  end

  # Attempt to answer the clue
  def attempt_answer(user, guess)
    clue = current_clue
    response = {duplicate: false, correct: false, clue_gone: clue.nil?, score: 0}

    unless clue.nil?
      valid_attempt = @redis.set("attempt:#{channel}:#{user}:#{clue['id']}", '',
                                 ex: ENV['ANSWER_TIME_SECONDS'].to_i * 2, nx: true)
      if valid_attempt
        if _is_correct?(clue['answer'], guess)
          clue_answered
          response[:score] = User.get(user).update_score(channel, clue['value'])
          response[:correct] = true
        else
          response[:score] = User.get(user).update_score(channel, clue['value'] * -1)
        end
      else
        response[:duplicate] = true
      end
    end
    response
  end

  def _is_correct?(correct, response)
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

  def remaining_clue_count
    @redis.scard("game:#{channel}:clues")
  end

  def scoreboard
    leaders = []
    @redis.scan_each(:match => "game_score:#{channel}:*"){ |key| user_id = key.gsub("game_score:#{channel}:", ''); leaders << { :user_id => user_id, :score => User.get(user_id).score(channel) } }
    puts "[LOG] Scoreboard: #{leaders.to_s}"
    leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }
  end

  def leaderboard(bottom = false)
    leaders = []
    @redis.scan_each(:match => "score:#{channel}:*"){ |key| user_id = key.gsub("score:#{channel}:", ''); leaders << { :user_id => user_id, :score => User.get(user_id).historic_score(channel) } }
    puts "[LOG] Leaderboard: #{leaders.to_s}"
    if bottom
      leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.reverse.take(10)
    else
      leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.take(10)
    end
  end

  def _clean_clue(clue)
    clue['value'] = 200 if clue['value'].nil?
    clue['answer'] = Sanitize.fragment(clue['answer'])
                       .gsub(/[^\w\s]/i, '')
                       .gsub(/^(the|a|an) /i, '')
                       .gsub(/\s+(&nbsp;|&)\s+/i, ' and ')
                       .strip
                       .downcase

    # Skip clues with empty questions or answers or if they've been voted as invalid
    if (!clue['answer'].nil? || !clue['question'].nil?) && clue['invalid_count'].nil?
      clue
    end
  end

end

class User < Mapper::Model
  attr_accessor :user_id, :redis

  def User.get(user_id)
    user = User.new
    user.user_id = user_id
    user.redis = Mapper.redis
    user
  end

  def is_moderator?(global = false)
    @redis.sismember('global_moderators', user_id) || (!global && @redis.sismember('moderators', user_id))
  end

  def make_moderator(global = false)
    if global
      @redis.sadd('global_moderators', user_id)
    end
    @redis.sadd('moderators', user_id)
  end

  def profile
    user = @redis.hgetall("user:#{user_id}")
    if user.nil? || user.empty?
      user = _get_slack_user_profile
    end
    user
  end

  def score(channel)
    key = "game_score:#{channel}:#{user_id}"
    current_score = @redis.get(key)
    if current_score.nil?
      0
    else
      current_score.to_i
    end
  end

  def historic_score(channel)
    key = "score:#{channel}:#{user_id}"
    current_score = @redis.get(key)
    if current_score.nil?
      0
    else
      current_score.to_i
    end
  end

  def update_score(channel, score, add = true)
    game_key = "game_score:#{channel}:#{user_id}"
    historic_key = "score:#{channel}:#{user_id}"

    @redis.sadd("players:#{channel}", user_id)
    if add
      @redis.incrby(game_key, score)
      @redis.incrby(historic_key, score)
    else
      @redis.decrby(game_key, score)
      @redis.decrby(historic_key, score)
    end

    @redis.get(game_key)
  end

  def _get_slack_user_profile
    uri = "https://slack.com/api/users.info?user=#{user_id}&token=#{ENV['SLACK_API_TOKEN']}"
    request = HTTParty.get(uri)
    response = JSON.parse(request.body)
    if response['ok']
      user = response['user']
      # Strings are used as hash keys because redis won't make them into symbols during hmget
      name = { 'id' => user['id'], 'name' => user['name']}
      unless user['profile'].nil?
        name['real'] = user['profile']['real_name'] unless user['profile']['real_name'].nil? || user['profile']['real_name'] == ''
        name['first'] = user['profile']['first_name'] unless user['profile']['first_name'].nil? || user['profile']['first_name'] == ''
        name['first'] = user['profile']['last_name'] unless user['profile']['last_name'].nil? || user['profile']['last_name'] == ''
      end
      @redis.pipelined do
        @redis.mapped_hmset("user:#{name[:id]}", name)
        @redis.expire("user:#{name[:id]}", 60*24*7) # one week
      end
      name
    end
  end
end

class Admin < Mapper::Model
  def self.build_category_cache
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
          self.redis.sadd('categories', category['id']) # Have a category set because of the super useful SRANDMEMBER
        end
      end
      break if response.size == 0 || offset >= 25000 # For safety or something
      offset = offset + 100
    end
  end

  def self.flush!
    self.redis.flushdb
  end
end
