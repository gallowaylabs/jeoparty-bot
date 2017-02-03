require_relative 'mapper'

module Jeoparty
  class User < Mapper::Model
    attr_accessor :id, :redis

    def User.get(user_id)
      user = User.new
      user.id = user_id
      user.redis = Mapper.redis
      user
    end

    def is_moderator?
      @redis.sismember('global_moderators', id) || @redis.sismember('moderators', id)
    end

    def is_global_moderator?
      @redis.sismember('global_moderators', id)
    end

    def make_moderator(options = nil)
      if options == :global
        @redis.sadd('global_moderators', id)
      end
      @redis.sadd('moderators', id)
    end

    def profile
      user = @redis.hgetall("user:#{id}")
      if user.nil? || user.empty?
        user = _get_slack_user_profile
      end
      user
    end

    def score(game_id)
      key = "game_score:#{game_id}:#{id}"
      current_score = @redis.get(key)
      if current_score.nil?
        0
      else
        current_score.to_i
      end
    end

    def historic_score(channel)
      key = "score:#{channel}:#{id}"
      current_score = @redis.get(key)
      if current_score.nil?
        0
      else
        current_score.to_i
      end
    end

    def update_score(game_id, channel_id, score, add = true)
      game_key = "game_score:#{game_id}:#{id}"
      historic_key = "score:#{channel_id}:#{id}"

      @redis.sadd("players:#{game_id}", id)
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
      uri = "https://slack.com/api/users.info?user=#{id}&token=#{ENV['SLACK_API_TOKEN']}"
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
          @redis.mapped_hmset("user:#{name['id']}", name)
          @redis.expire("user:#{name['id']}", 60*24*7) # one week
        end
        name
      end
    end
  end
end
