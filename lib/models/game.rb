require 'text'
require 'json'
require 'httparty'
require 'sanitize'

require_relative 'mapper'

module Jeoparty
  class Game < Mapper::Model
    attr_accessor :id, :categories, :redis

    def Game.get(channel, id)
      Game.new(channel, id)
    end

    # Start a new game
    def initialize(channel, id)
      @redis = Mapper.redis
      @channel = channel
      @id = id
    end

    def self.new_game(channel, mode)
      game = Game.new(channel, Time.now.to_f.to_s) # Ugly, but at least we can sort on it easily
      if mode == 'random'
        self._build_random_game(game)
      else
        self._build_standard_game(game)
      end
      game
    end

    def self._build_standard_game(game)
      category_names = []
      # Pick 12 random categories. The game will only use 6, but this gives wiggle room for weird
      # situations where categories are unusable for one reason or another
      categories = []
      12.times { categories << rand(ENV['MAX_CATEGORY_ID'].to_i) }
      categories.uniq!
      valid_categories = 0

      categories.each do |category|
        uri = "http://jservice.io/api/clues?category=#{category}"
        request = HTTParty.get(uri)
        response = JSON.parse(request.body)

        if response.empty?
          next
        end

        date_sorted = response.sort_by { |k| k['airdate']}

        # If there are >5 clues, pick a random air date to use and take all clues from that date
        selected = date_sorted.drop(rand(date_sorted.size / 5) * 5).take(5)

        selected.each do |clue|
          clue = _clean_clue(clue)
          unless clue.nil? || clue.empty?  # Don't add degenerate clues
            clue_key = "game_clue:#{game.id}:#{clue['id']}"
            game.redis.set(clue_key, clue.to_json)
            game.redis.sadd("game:#{game.id}:clues", clue_key)
          end
        end

        category_names.append(selected.first['category']['title'])
        valid_categories += 1
        break if valid_categories >= 6
      end
      game.categories = category_names
    end

    def self._build_random_game(game)
      uri = 'http://jservice.io/api/random'

      30.times do
        request = HTTParty.get(uri)
        response = JSON.parse(request.body)

        clue = _clean_clue(response.first)
        unless clue.nil? || clue.empty?  # Don't add degenerate clues
          clue_key = "game_clue:#{game.id}:#{clue['id']}"
          game.redis.set(clue_key, clue.to_json)
          game.redis.sadd("game:#{game.id}:clues", clue_key)
        end
      end
    end

    def start_category_vote(message_id)
      category_vote_key = "game:#{@id}:vote:#{message_id}"
      @redis.set(category_vote_key, 0)
      @redis.expire(category_vote_key, 2*60) # 2 minutes
    end

    # Clean up artifacts of this game
    def cleanup
      @redis.scan_each(:match => "game_clue:#{@id}:*"){ |key| @redis.del(key) }

      @redis.del("game:#{@id}:clues")
      @redis.del("game:#{@id}:current")
    end

    # Get clue from the current game by ID
    def get_clue(clue_id)
      clue = @redis.get("game_clue:#{@id}:#{clue_id}")
      unless clue.nil?
        JSON.parse(clue)
      end
    end

    # Get the current clue in this game
    def current_clue
      clue = @redis.get("game:#{@id}:current")

      unless clue.nil?
        JSON.parse(clue)
      end
    end

    # Get a clue, remove it from the pool and mark it as active in one 'transaction'
    def next_clue
      game_clue_key = "game:#{@id}:clues"
      current_clue_key = "game:#{@id}:current"

      clue_key = @redis.srandmember(game_clue_key)
      unless clue_key.nil?
        clue = @redis.get(clue_key)
        parsed_clue = JSON.parse(clue)

        @redis.pipelined do
          @redis.srem(game_clue_key, clue_key)
          @redis.set(current_clue_key, clue)
        end
        parsed_clue
      end
    end

    def record_bid(user, bid)
      clue = current_clue
      unless clue.nil? || clue['daily_double'].nil?
        @redis.pipelined do
          @redis.set("bid:#{@id}:#{clue['id']}:#{user}", bid, ex: ENV['ANSWER_TIME_SECONDS'].to_i * 3)
          @redis.sadd("bid:#{@id}:#{clue['id']}", user)
        end
      end
    end

    def get_bid(user, clue_id)
      @redis.get("bid:#{@id}:#{clue_id}:#{user}")
    end

    def pick_daily_double_user
      bid_pool_key = "bid:#{@id}:#{clue['id']}"
      clue = current_clue
      user = @redis.srandmember(bid_pool_key)
      @redis.set("dailydouble:#{@id}:#{clue['id']}:#{user}", '', ex: ENV['ANSWER_TIME_SECONDS'].to_i * 3)
      @redis.del(bid_pool_key)
      user
    end

    def daily_double_user?(user, clue_id)
      @redis.exists("dailydouble:#{@id}:#{clue_id}:#{user}")
    end

    # Mark clue as answered
    def clue_answered
      @redis.del("game:#{@id}:current")
    end

    # Attempt to answer the clue
    def attempt_answer(user, guess, timestamp)
      clue = current_clue
      response = {duplicate: false, correct: false, bad_sport: false, show_answer: nil,
                  clue_gone: clue.nil?, score: 0}

      unless clue.nil?
        valid_attempt = @redis.set("attempt:#{@id}:#{user}:#{clue['id']}", '',
                                   ex: ENV['ANSWER_TIME_SECONDS'].to_i * 3, nx: true)
        if valid_attempt
          correctness = _is_correct?(clue, guess)
          response[:correct] = correctness[:correct]
          # Show the answer if the user was close but not exact.
          if correctness[:close] && !correctness[:exact]
            response[:show_answer] = clue['answer']
          end

          if clue['daily_double']
            # Handle the case where someone is a bad sport and answers the daily double when it isn't their turn
            unless daily_double_user?(user, clue['id'])
              response[:correct] = false
              response[:bad_sport] = true
            end
            value = get_bid(user, clue['id'])
            response[:show_answer] = clue['answer']
          else
            value = clue['value']
          end
          response[:score] = update_score(user, value, response[:correct])

          if response[:correct] || (clue['daily_double'] && !response[:bad_sport])
            clue_answered
          end
          _record_answer(user, clue, response[:correct], timestamp)
        else
          response[:duplicate] = true
        end
      end
      response
    end

    def _is_correct?(clue, response)
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
      similarity = white.similarity(clue['answer'], response)

      alt_similarity = 0
      unless clue['alternate'].nil?
        alt_similarity = white.similarity(clue['alternate'], response)
      end

      puts "[LOG] User answer: #{response} | Correct answer (#{similarity}): #{clue['answer']} | Alternate answer (#{alt_similarity}): #{clue['alternate']}"

      response = {}
      response[:exact] = clue['answer'] == response || clue['alternate'] == response || similarity == 1.0 || alt_similarity == 1.0
      response[:close] = similarity >= ENV['SIMILARITY_THRESHOLD'].to_f || alt_similarity >= ENV['SIMILARITY_THRESHOLD'].to_f
      response[:correct] = response[:exact] || response[:close]
      response
    end

    def remaining_clue_count
      @redis.scard("game:#{@id}:clues")
    end

    def scoreboard
      leaders = []
      scores = @redis.hgetall("game_score:#{@id}")
      unless scores.nil?
        scores.each {|k,v| leaders << {user_id: k, score: v}}
        leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }
      end
    end

    def user_score(user)
      score = @redis.hmget("game_score:#{@id}", user)
      unless score.nil?
        score.first
      end
    end

    def update_score(user, amount, correct)
      @redis.sadd("game_players:#{@id}", user)
      @redis.hincrby("game_score:#{@id}", user, correct ? amount : amount * -1)
    end

    def moderator_update_score(user, timestamp, reset = false)
      key = "response:#{@id}:#{user}:#{timestamp}"
      response = @redis.hgetall(key)
      unless response.nil? or response.empty?
        # correct != true because we want correct answers to be subtracted from and incorrect to be added to
        value = reset ? response['value'].to_i : response['value'].to_i * 2
        @redis.del(key) # Avoid double score modifications
        update_score(user, value, response['correct'] != 'true')
      end
    end

    def category_vote(message_id, score)
      key = "game:#{@id}:vote:#{message_id}"
      if @redis.exists(key)
        @redis.incrby(key, score)
      end
    end

    def self._clean_clue(clue)
      if clue['value'].nil?
        clue['daily_double'] = true
      end
      answer_sanitized = Sanitize.fragment(clue['answer'].gsub(/\s+(&nbsp;|&)\s+/i, ' and '))
                           .gsub(/^(the|a|an) /i, '')
                           .gsub('=', '')
                           .strip
                           .downcase

      # Parens at the end often indicate alternative answers that may be used instead of the primary answer
      alternate = answer_sanitized.match(/.+\((.*)\)/)
      unless alternate.nil?
        clue['alternate'] = alternate[1].gsub(/^(or|alternatively|alternate) /i, '').gsub(/[^\/[[:alnum:]]\s\-]/i, '')
      end

      # Parens at the beginning often indicate optional first names, so the alternate here
      # is for if the user used the whole name as the "answer" now has the optional first part removed
      alternate = answer_sanitized.match(/^\((.*)\)/)
      unless alternate.nil?
        clue['alternate'] = answer_sanitized.gsub(/[^\/[[:alnum:]]\s\-]/i, '')
      end

      clue['answer'] = answer_sanitized.gsub(/\(.*\)/, '').gsub(/[^\/[[:alnum:]]\s\-]/i, '')

      # Skip clues with empty questions or answers or if they've been voted as invalid
      if !clue['answer'].nil? && !clue['question'].nil? && !clue['question'].empty? && clue['invalid_count'].nil?
        clue
      end
    end

    def _record_answer(user, clue, correct, timestamp)
      key = "response:#{@id}:#{user}:#{timestamp}"
      @redis.pipelined do
        @redis.hmset(key, 'clue_id', clue['id'], 'value', clue['value'], 'correct', correct)
        @redis.expire(key, 600) # 10 minute review time
      end
    end
  end
end
