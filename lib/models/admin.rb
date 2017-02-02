require_relative 'mapper'

module Jeoparty
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

    def self.asleep?
      self.redis.exists('sleep_mode')
    end

    def self.sleep!(seconds = nil)
      self.redis.set('sleep_mode', 'yes')
      unless seconds.nil?
        self.redis.expire('sleep_mode', seconds)
      end
    end

    def self.wake!
      self.redis.del('sleep_mode')
    end

    def self.flush!
      self.redis.flushdb
    end
  end
end
