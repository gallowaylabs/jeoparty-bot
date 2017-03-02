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

    def is_global_moderator?
      @redis.sismember('global_moderators', id)
    end

    def make_global_moderator
      @redis.sadd('global_moderators', id)
    end

    def profile
      user = @redis.hgetall("user:#{id}")
      if user.nil? || user.empty?
        user = _get_slack_user_profile
      end
      user
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
        end

        # Fallback for users without real names (usually bots or guests)
        if name['real'].nil? || name['real'].empty?
          name['real'] = user['name']
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
