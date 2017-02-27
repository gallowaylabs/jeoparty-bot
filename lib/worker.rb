require 'slack-ruby-bot'
require 'eventmachine'
require 'dotenv'
require 'redis'

require_relative 'models/game'
require_relative 'models/channel'
require_relative 'models/user'
require_relative 'models/admin'
require_relative 'hooks.rb'

module Jeoparty
  class JeopartyBot < SlackRubyBot::Bot
    match /^next\s*($|answer|clue)/i do |client, data, match|
      game = Channel.get(data.channel).game
      guesser = nil

      # Only post a question if none is in progress
      if !game.nil? && game.current_clue.nil?
        clue = game.next_clue

        if clue.nil?
          # Game is over, show the scoreboard
          players = format_board(game.scoreboard)
          unless players.nil?
            client.say(text: "The game is over :tada: The scores for this game were:\n> #{players.join("\n>")}",
                       channel: data.channel)
          end
        else
          skip_wait = false
          # On to the next clue
          if clue['daily_double']
            client.say(text: %Q{*Daily Double!* The category is: \n>#{clue['category']['title']}\nYou have #{ENV['ANSWER_TIME_SECONDS'].to_i / 2} seconds to enter your bid of $100 to $1000 with `bid <amount>`},
                       channel: data.channel)

            EM.defer do
              sleep ENV['ANSWER_TIME_SECONDS'].to_i / 2
              guesser = game.pick_daily_double_user
              if guesser.nil?
                client.say(text: 'No bids? I do suppose that the only winning move is not to play', channel: data.channel)
                game.clue_answered
                skip_wait = true
              else
                client.say(text: ":game_die: <@#{guesser}>, you have been selected to answer this clue! Answers from other players will result in a penalty.",
                           channel: data.channel)
                bid = game.get_bid(guesser, clue['id'])
                post_clue(clue, client, data.channel, value: bid)
              end
            end
          else
            post_clue(clue, client, data.channel)
          end

          unless skip_wait
            EM.defer do
              sleep ENV['ANSWER_TIME_SECONDS'].to_i + (clue['daily_double']? ENV['ANSWER_TIME_SECONDS'].to_i / 2 : 0)
              # Fetch the current clue. Show the answer if the current clue was the
              # one that was asked ANSWER_TIME_SECONDS ago. This is to avoid the race condition
              # where a clue is answered and a new one is requested in less than ANSWER_TIME_SECONDS
              latest = game.current_clue
              if !latest.nil? && latest['id'] == clue['id']
                if latest['daily_double']
                  verdict = game.attempt_answer(guesser, '', nil)
                  client.say(text: "Time is up! <@#{guesser}> your score is now #{Util.format_currency(verdict[:score])}. The answer was \n> #{clue['answer']}", channel: data.channel)
                else
                  client.say(text: "Time is up! The answer was \n> #{clue['answer']}", channel: data.channel)
                end
                game.clue_answered
              end
            end
          end
        end
      end
    end

    match /^(what|whats|where|wheres|who|whos|when|whens) /i do |client, data, match|
      verdict = Channel.get(data.channel).game&.attempt_answer(data.user, data.text, data.ts)

      if verdict[:bad_sport]
        client.say(text: "It isn't your daily double clue <@#{data.user}>! Your score is now #{Util.format_currency(verdict[:score])}", channel: data.channel)
      elsif verdict[:duplicate]
        client.say(text: "Only one guess per clue is allowed <@#{data.user}>!", channel: data.channel)
      elsif verdict[:correct]
        text = "That is the correct answer <@#{data.user}> :tada: Your score is now #{Util.format_currency(verdict[:score])}."
        unless verdict[:show_answer].nil?
          text += "\nThe exact answer was:\n>#{verdict[:show_answer]}"
        end
        client.say(text: text, channel: data.channel)
      elsif !verdict[:clue_gone] && !verdict[:correct]
        text = "Sorry <@#{data.user}>, that is incorrect. Your score is now #{Util.format_currency(verdict[:score])}"
        unless verdict[:show_answer].nil?
          text += "\nThe correct answer was:\n>#{verdict[:show_answer]}"
        end
        client.say(text: text, channel: data.channel)
      end
    end

    match /^(bid|bet) (?<bid>\d*)$/i do |client, data, match|
      bid = [100, [1000, match[:bid].to_i].min].max
      Channel.get(data.channel).game&.record_bid(data.user, bid)
      client.say(text: "<@#{data.user}>, you have bid #{Util.format_currency(bid)}", channel: data.channel)
    end


    match /^show\s*(my)?\s*score\s*$/i do |client, data, match|
      score = Channel.get(data.channel).game&.user_score(data.user)
      client.say(text: "<@#{data.user}>, your score is #{Util.format_currency(score)}", channel: data.channel)
    end

    match /^(new|start) (?<mode>random|standard|)\s*game/i do |client, data, match|
      clue_count = Channel.get(data.channel).game&.remaining_clue_count

      if Admin.asleep?
        client.say(text: "#{client.self.name} is currently sleeping. Moderators may wake it up with `<@#{client.self.id}> wake`",
                   channel: data.channel)
      else
        # Only start a new game if the previous game is over
        if clue_count.nil? || clue_count == 0
          game = Channel.get(data.channel).new_game(match[:mode])

          if game.categories.nil?
            text = %Q{<!here> *Starting a new game* 30 random clues have been chosen
            \n Add :+1: or :-1: reactions to this post to keep or cancel this game mode}
          else
            text = %Q{<!here> *Starting a new game!* The categories today are:\n• #{game.categories.join("\n• ")}
            \n\n Add :+1: or :-1: reactions to this post to keep or redo these categories}
          end
          # Yes, the unicode bullet point makes me sad as well
          message = client.web_client.chat_postMessage(
            channel: data.channel,
            as_user: true,
            text: text
          )
          game.start_category_vote(message.ts)
        else
          client.say(text: "Not yet! There are still #{clue_count} clues remaining", channel: data.channel)
        end
      end
    end

    match /^skip\s?(clue)?/i do |client, data, match|
      if Channel.get(data.channel).is_user_moderator?(data.user)
        game = Channel.get(data.channel).game
        unless game.nil?
          clue = game.current_clue
          game.clue_answered
          client.say(text: "Clue skipped! The answer was: \n> #{clue['answer']}", channel: data.channel)
        end
      end
    end

    match /^clues remaining/i do |client, data, match|
      clue_count = Channel.get(data.channel).game&.remaining_clue_count
      unless clue_count.nil?
        client.say(text: "There are #{clue_count} clues remaining", channel: data.channel)
      end
    end

    match /^show\s*(the)? top (?<count>\d*)\s*(players|scores)?/i do |client, data, match|
      players = format_board(Channel.get(data.channel).leaderboard(match[:count].to_i))
      client.say(text: "The top #{match[:count]} players across all games are:\n> #{players.join("\n>")}",
                 channel: data.channel)
    end

    match /^show\s*(the)? scoreboard/i do |client, data, match|
      players = format_board(Channel.get(data.channel).game&.scoreboard)
      unless players.empty?
        client.say(text: "The scores for this game are:\n> #{players.join("\n>")}", channel: data.channel)
      end
    end

    match /^show\s*(the)? leaderboard/i do |client, data, match|
      players = format_board(Channel.get(data.channel).leaderboard(10))
      client.say(text: "The highest scoring players across all games are:\n> #{players.join("\n>")}",
                 channel: data.channel)
    end

    match /^show\s*(the)? loserboard/i do |client, data, match|
      players = format_board(Channel.get(data.channel).leaderboard(10, true))
      client.say(text: "The lowest scoring players across all games are:\n> #{players.join("\n>")}",
                 channel: data.channel)
    end

    match /^judges adjust \<@(?<user>[\w\d]*)\>\s* (?<value>[-\d]*)/i do |client, data, match|
      if !match[:value].nil? && !match[:user].nil? && Channel.get(data.channel).is_user_moderator?(data.user)
        game = Channel.get(data.channel).game
        new_score = User.get(match[:user]).update_score(game.id, data.channel, match[:value])
        client.say(text: "<@#{match[:user]}>, your score is now #{Util.format_currency(new_score)}",
                   channel: data.channel)
      end
    end

    command 'cancel game' do |client, data, match|
      if Channel.get(data.channel).is_user_moderator?(data.user)
        Channel.get(data.channel).game&.cleanup
        client.say(text:'Game cancelled', channel: data.channel)
      end
    end

    command 'flush database' do |client, data, match|
      if User.get(data.user).is_global_moderator?
        Admin.flush!
        client.say(text:'Database flushed.', channel: data.channel)
      end
    end

    command 'sleep' do |client, data, match|
      if User.get(data.user).is_global_moderator?
        Admin.sleep!
        client.say(text:"Going to sleep :sleeping:. Wake me up with `<@#{client.self.id}> wake`", channel: data.channel)
      end
    end

    command 'wake' do |client, data, match|
      if User.get(data.user).is_global_moderator?
        Admin.wake!
        client.say(text:':sunny: Ready for a game? Type `new game`!', channel: data.channel)
      end
    end

    match /^use token (?<token>[\w\d]*)\s*/i do |client, data, match|
      if !match[:token].nil? && match[:token] == ENV['GLOBAL_MOD_TOKEN']
        User.get(data.user).make_global_moderator
        client.say(text: 'You are now a global moderator. Add other moderators with `add moderator @name`',
                   channel: data.channel)
      end
    end

    match /^add moderator \<@(?<user>[\w\d]*)\>\s*/i do |client, data, match|
      if Channel.get(data.channel).is_user_moderator?(data.user) && !match[:user].nil?
        Channel.get(data.channel).make_moderator(match[:user])
        client.say(text: "<@#{match[:user]}> is now a moderator in this channel", channel: data.channel)
      end
    end

    command 'about' do |client, data, match|
      about = %Q{Jeoparty Bot! is open source software. Pull requests welcome. \n
Questions provided by jService: http://jservice.io/ \n
Powered by slack-ruby-bot: https://github.com/slack-ruby/slack-ruby-bot \n
Source code available at: https://github.com/esbdotio/jeoparty-bot.
      }
      client.say(text: about, channel: data.channel)
    end

    # Monkey patch help because of the extra junk that the framework adds
    command 'help' do |client, data, match|
      commands = SlackRubyBot::CommandsHelper.instance.bot_desc_and_commands
      client.say(text: commands, channel: data.channel)
    end

    help do
      title 'Jeoparty Bot!'
      desc 'The punniest trivia questions since 1978'

      command 'new game' do
        desc 'Start a new game with the usual 6 categories of 5 clues each.'
      end

      command 'new random game' do
        desc 'Start a new game with 30 totally random clues.'
      end

      command 'next' do
        desc 'Give the next clue. Remember to answer in the form of a question!'
      end

      command 'what is <answer>' do
        desc 'Try to solve the current clue with <answer>. Other valid triggers are who, what, and when.'
      end

      command 'clues remaining' do
        desc 'The number of clues remaining in the current game'
      end

      command 'show my score' do
        desc 'Shows your score in the current game'
      end

      command 'show scoreboard' do
        desc 'Shows all players scores in the current game'
      end

      command 'show top (number) players' do
        desc 'Shows the top (number) of players across all games'
      end
      command 'show leaderboard' do
        desc 'Shows the top 10 players across all games'
      end

      command 'show loserboard' do
        desc 'Shows the bottom 10 players across all games'
      end

      command 'skip' do
        desc '(Moderator only) Skip the current clue'
      end
    end

    # Format (leader|loser|score)board
    def self.format_board(board)
      players = []
      board.each_with_index do |user, i|
        name = User.get(user[:user_id]).profile
        players << "#{i + 1}. #{name['real']}: #{Util.format_currency(user[:score])}"
      end
      players
    end

    def self.post_clue(clue, client, channel, value: nil)
      air_date = Time.iso8601(clue['airdate']).to_i

      if value.nil?
        value = clue['value']
      end

      client.web_client.chat_postMessage(
        channel: channel,
        as_user: true,
        attachments: [
          {
            fallback: "#{clue['category']['title']} for $#{value}: `#{clue['question']}`",
            title: "#{clue['category']['title']} for $#{value}",
            text: "#{clue['question']}",
            footer: "Clue #{clue['id']}",
            ts: "#{air_date}"
          }
        ]
      )
    end
  end

  EM.run do
    # Load .env vars
    Dotenv.load
    # Disable output buffering
    $stdout.sync = true

    # Set up redis
    uri = URI.parse(ENV['REDIS_URL'])
    Mapper.redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)

    SlackRubyBot::Client.logger.level = Logger::WARN

    bot1 = SlackRubyBot::Server.new(token: ENV['SLACK_API_TOKEN'], aliases: ['tb'])
    bot1.hooks.add(:reaction_added, Jeoparty::Hooks::ReactionAdded.new)
    bot1.start_async
  end
end
