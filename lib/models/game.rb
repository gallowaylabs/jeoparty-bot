require 'text'
require 'json'
require 'httparty'
require 'sanitize'

require_relative 'mapper'

module Jeoparty
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
            clue_key = "game_clue:#{channel}:#{clue['id']}"
            @redis.set(clue_key, clue.to_json)
            @redis.sadd("game:#{channel}:clues", clue_key)
          end
        end

        category_names.append(selected.first['category']['title'])
        valid_categories += 1
        break if valid_categories >= 6
      end

      category_vote_key = "game:#{channel}:category_vote"
      @redis.set(category_vote_key, 0)
      @redis.expire(category_vote_key, 2*60) # 2 minutes

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
      @redis.del("game:#{channel}:category_vote")
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
    def attempt_answer(user, guess, timestamp)
      clue = current_clue
      response = {duplicate: false, correct: false, clue_gone: clue.nil?, score: 0}

      unless clue.nil?
        valid_attempt = @redis.set("attempt:#{channel}:#{user}:#{clue['id']}", '',
                                   ex: ENV['ANSWER_TIME_SECONDS'].to_i * 2, nx: true)
        if valid_attempt
          response[:correct] = _is_correct?(clue, guess)
          response[:score] = User.get(user).update_score(channel, clue['value'], response[:correct])

          if response[:correct]
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

      clue['answer'] == response || clue['alternate'] == response ||
        similarity >= ENV['SIMILARITY_THRESHOLD'].to_f || alt_similarity >= ENV['SIMILARITY_THRESHOLD'].to_f
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

    def moderator_update_score(user, timestamp, reset = false)
      key = "response:#{channel}:#{user}:#{timestamp}"
      response = @redis.hgetall(key)
      unless response.nil? or response.empty?
        # correct != true because we want correct answers to be subtracted from and incorrect to be added to
        value = reset ? response['value'].to_i : response['value'].to_i * 2
        @redis.del(key) # Avoid double score modifications
        User.get(user).update_score(channel, value, response['correct'] != 'true')
      end
    end

    def category_vote(score)
      key = "game:#{channel}:category_vote"
      if @redis.exists(key)
        @redis.incrby("game:#{channel}:category_vote", score)
      end
    end

    def _clean_clue(clue)
      clue['value'] = 200 if clue['value'].nil?
      answer_sanitized = Sanitize.fragment(clue['answer'].gsub(/\s+(&nbsp;|&)\s+/i, ' and '))
                           .gsub(/^(the|a|an) /i, '')
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
      if (!clue['answer'].nil? || !clue['question'].nil?) && clue['invalid_count'].nil?
        clue
      end
    end

    def _record_answer(user, clue, correct, timestamp)
      key = "response:#{channel}:#{user}:#{timestamp}"
      @redis.pipelined do
        @redis.hmset(key, 'clue_id', clue['id'], 'value', clue['value'], 'correct', correct)
        @redis.expire(key, 600) # 10 minute review time
      end
    end
  end
end
