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
      leaders = []
      @redis.scan_each(:match => "score:#{@id}:*"){ |key| user_id = key.gsub("score:#{@id}:", ''); leaders << { :user_id => user_id, :score => User.get(user_id).historic_score(@id) } }
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
  end
end
