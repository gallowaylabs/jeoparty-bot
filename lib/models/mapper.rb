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
