require_relative 'mapper'
require_relative 'game'

module Jeoparty
  class Channel < Mapper::Model
    def initialize(id)
      @id = id
      @redis = Mapper.redis
    end

    def Channel.get(id)
      Channel.new(id)
    end

    def game
      game_id = @redis.get("channel:#{@id}:current_game")
      Game.get(@id, game_id)
    end

    def game_in_progress?
      @redis.exists("channel:#{@id}:current_game")
    end

    def new_game(mode)
      key = "channel:#{@id}:current_game"
      current = @redis.get(key)
      game = Game.get(@id, current)
      if game&.remaining_clue_count > 0
        nil
      else
        game.cleanup
        game = Game.new_game(@id, mode)
        @redis.set(key, game.id)
        @redis.sadd("channel:#{@id}:games", game.id)
        puts "Created new game in channel #{@id} with id #{game.id}"
        game
      end
    end

    def leaderboard(count, bottom = false)
      now = Date.today
      first_date = Date.new(now.year, now.month, 1).to_time.to_f
      scores = {}

      games = @redis.smembers("channel:#{@id}:games")
      filtered = games.select { |k| k.to_f > first_date }
      filtered.each do |id|
        game_scores = @redis.hgetall("game_score:#{id}")
        game_scores.each do |k, v|
          if scores[k].nil?
            scores[k] = v.to_i
          else
            scores[k] += v.to_i
          end
        end
      end

      leaders = []
      scores.each {|k,v| leaders << {user_id: k, score: v}}
      if bottom
        leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.reverse.take(count)
      else
        leaders.uniq{ |l| l[:user_id] }.sort{ |a, b| b[:score] <=> a[:score] }.take(count)
      end
    end

    def is_user_moderator?(user)
      @redis.sismember('global_moderators', user) || @redis.sismember("moderators:#{@id}", user)
    end

    def make_moderator(user)
      @redis.sadd("moderators:#{@id}", user)
    end

    def remove_moderator(user)
      @redis.srem("moderators:#{@id}", user)
    end

    def assume_moderator(user)
      if @redis.scard("moderators:#{@id}") == 0
        @redis.sadd("moderators:#{@id}", user)
        true
      end
    end
  end
end
