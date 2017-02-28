require_relative 'models/user'
require_relative 'models/game'
require_relative 'util.rb'

module Jeoparty
  module Hooks
    # Hook when reactions are added. Used as a shortcut for
    # judges and category shuffling
    class ReactionAdded
      def call(client, data)
        game = Channel.get(data['item']['channel']).game
        unless game.nil?
          emoji = Util.base_emoji(data['reaction'])
          adjust_emoji = %w(white_check_mark negative_squared_cross_mark)
          if adjust_emoji.include?(emoji) && Channel.get(data['item']['channel']).is_user_moderator?(data['user'])
            new_score = game.moderator_update_score(data['item_user'], data['item']['ts'])
            unless new_score.nil?
              client.say(text: "<@#{data['item_user']}>, the judges have reviewed your answer. Your score is now #{Util.format_currency(new_score)}",
                         channel: data['item']['channel'])
            end
          end

          if %w(+1 -1).include?(emoji)
            score = game.category_vote(data['item']['ts'], emoji.to_i) # Hilariously inadvisable
            if !score.nil? && score.to_i <= ENV['CATEGORY_SHUFFLE_MINIMUM'].to_i
              game.cleanup
              client.say(text: 'Category shuffle vote passed. You may try your luck at category selection again with `start game`',
                         channel: data['item']['channel'])
            end
          end
        end
      end
    end
  end
end
