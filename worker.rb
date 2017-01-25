require 'slack-ruby-bot'
require 'eventmachine'
require 'json'
require 'httparty'
require 'sanitize'
require 'time'
require 'dotenv'
require 'redis'
require 'text'

require_relative 'models.rb'
require_relative 'hooks.rb'

module Jeoparty
  class JeopartyBot < SlackRubyBot::Bot
    match /^next\s*($|answer|clue)/i do |client, data, match|
      clue = Game.in(data.channel).current_clue

      # Only post a question if none is in progress
      if clue.nil?
        clue = Game.in(data.channel).next_clue

        if clue.nil?
          # Game is over, show the scoreboard
          players = format_board(Game.in(data.channel).scoreboard)
          unless players.nil?
            client.say(text: "The game is over :tada: The scores for this game were:\n> #{players.join("\n>")}",
                       channel: data.channel)
          end
        else
          # On to the next clue
          air_date = Time.iso8601(clue['airdate']).to_i

          client.web_client.chat_postMessage(
              channel: data.channel,
              as_user: true,
              attachments: [
                {
                  fallback: "#{clue['category']['title']} for $#{clue['value']}: `#{clue['question']}`",
                  title: "#{clue['category']['title']} for $#{clue['value']}",
                  text: "#{clue['question']}",
                  footer: "Clue #{clue['id']}",
                  ts: "#{air_date}"
                }
              ]
          )

          EM.defer do
            sleep ENV['ANSWER_TIME_SECONDS'].to_i
            # Fetch the current clue. Show the answer if the current clue was the
            # one that was asked ANSWER_TIME_SECONDS ago. This is to avoid the race condition
            # where a clue is answered and a new one is requested in less than ANSWER_TIME_SECONDS
            latest = Game.in(data.channel).current_clue
            if !latest.nil? && latest['id'] == clue['id']
              Game.in(data.channel).clue_answered
              client.say(text: "Time is up! The answer was \n> #{clue['answer']}", channel: data.channel)
            end
          end
        end
      end
    end

    match /^(what|whats|where|wheres|who|whos|when|whens) /i do |client, data, match|
      verdict = Game.in(data.channel).attempt_answer(data.user, data.text, data.ts)

      if verdict[:duplicate]
        client.say(text: "Only one guess per clue is allowed <@#{data.user}>!", channel: data.channel)
      elsif verdict[:correct]
        client.say(text: "That is the correct answer <@#{data.user}> :tada: Your score is now #{format_currency(verdict[:score])}",
                   channel: data.channel)
      elsif !verdict[:clue_gone] && !verdict[:correct]
        client.say(text: "Sorry <@#{data.user}>, that is incorrect. Your score is now #{format_currency(verdict[:score])}",
                   channel: data.channel)
      end
    end

    match /^show\s*(my)?\s*score\s*$/i do |client, data, match|
      score = User.get(data.user).score(data.channel)
      client.say(text: "<@#{data.user}>, your score is #{format_currency(score)}", channel: data.channel)
    end

    match /^(new|start) game/i do |client, data, match|
      clue_count = Game.in(data.channel).remaining_clue_count

      if Admin.asleep?
        client.say(text: "#{client.self.name} is currently sleeping. Moderators may wake it up with `<@#{client.self.id}> wake`",
                   channel: data.channel)
      else
        # Only start a new game if the previous game is over
        if clue_count.nil? || clue_count == 0
          category_names = Game.in(data.channel).new_game

          # Yes, the unicode bullet point makes me sad as well
          client.say(text: "*Starting a new game!* The categories today are:\n• #{category_names.join("\n• ")}"\
                            "\n\n Add :+1: or :-1: reactions to this post to keep or redo these categories",
                     channel: data.channel)
        else
          client.say(text: "Not yet! There are still #{clue_count} clues remaining", channel: data.channel)
        end
      end
    end

    match /^shuffle categories/i do |client, data, match|
      if User.get(data.user).is_moderator?
        category_names = Game.in(data.channel).new_game

        client.say(text: "*Starting a new game!* The categories today are:\n• #{category_names.join("\n• ")}",
                   channel: data.channel)
      end
    end

    match /^clues remaining/i do |client, data, match|
      clue_count = Game.in(data.channel).remaining_clue_count
      client.say(text: "There are #{clue_count} clues remaining", channel: data.channel)
    end

    match /^show scoreboard/i do |client, data, match|
      players = format_board(Game.in(data.channel).scoreboard)
      unless players.empty?
        client.say(text: "The scores for this game are:\n> #{players.join("\n>")}", channel: data.channel)
      end
    end

    match /^show leaderboard/i do |client, data, match|
      players = format_board(Game.in(data.channel).leaderboard)
      client.say(text: "The highest scoring players across all games are\n> #{players.join("\n>")}",
                 channel: data.channel)
    end

    match /^show loserboard/i do |client, data, match|
      players = format_board(Game.in(data.channel).leaderboard(true))
      client.say(text: "The lowest scoring players across all games are\n> #{players.join("\n>")}",
                 channel: data.channel)
    end

    match /^judges (?<verb>correct|incorrect|reset) \<@(?<user>[\w\d]*)\>\s* (?<clue>[\d]*)/i do |client, data, match|
      if !match[:verb].nil? && !match[:user].nil? && !match[:clue].nil? && User.get(data.user).is_moderator?
        clue = Game.in(data.channel).get_clue(match[:clue])
        unless clue.nil?
          if match[:verb] == reset
            new_score = User.get(match[:user]).update_score(data.channel, clue['value'])
            client.say(text: "<@#{match[:user]}>, your score is now #{format_currency(new_score)}",
                       channel: data.channel)
          else
            # Double value to make up for the lost points
            new_score = User.get(match[:user]).update_score(data.channel, clue['value'].to_i * 2, match[:verb].downcase == 'correct')
            client.say(text: "<@#{match[:user]}>, the judges reviewed your answer and found that you were #{match[:verb].downcase}. Your score is now #{format_currency(new_score)}",
                       channel: data.channel)
          end
        end
      end
    end

    command 'build category cache' do |client, data, match|
      if User.get(data.user).is_moderator?(true)
        client.say(text:'On it :+1:', channel: data.channel)
        Admin.build_category_cache
        client.say(text:'Category cache (re)build complete', channel: data.channel)
      end
    end

    command 'flush database' do |client, data, match|
      if User.get(data.user).is_moderator?(true)
        Admin.flush!
        client.say(text:'Database flushed. Be sure to `build category cache` before starting a new game',
                   channel: data.channel)
      end
    end

    command 'cancel game' do |client, data, match|
      if User.get(data.user).is_moderator?
        Game.in(data.channel).cleanup
        client.say(text:'Game cancelled', channel: data.channel)
      end
    end

    command 'sleep' do |client, data, match|
      if User.get(data.user).is_moderator?
        Admin.sleep!
        client.say(text:"Going to sleep :sleeping:. Wake me up with `<@#{client.self.id}> wake`", channel: data.channel)
      end
    end

    command 'wake' do |client, data, match|
      if User.get(data.user).is_moderator?
        Admin.wake!
        client.say(text:':sunny: Ready for a game? Type `new game`!', channel: data.channel)
      end
    end

    match /^use token (?<token>[\w\d]*)\s*/i do |client, data, match|
      if !match[:token].nil? && match[:token] == ENV['GLOBAL_MOD_TOKEN']
        User.get(data.user).make_moderator(true)
        client.say(text: 'You are now a global moderator. Add other moderators with `add moderator @name`',
                   channel: data.channel)
      end
    end

    match /^add moderator \<@(?<user>[\w\d]*)\>\s*/i do |client, data, match|
      if User.get(data.user).is_moderator?(true) && !match[:user].nil?
        User.get(match[:user]).make_moderator
        client.say(text: "<@#{match[:user]}> is now a moderator", channel: data.channel)
      end
    end

    # Monkey patch help because of the extra junk that the framework adds
    command 'help' do |client, data, match|
      commands = SlackRubyBot::CommandsHelper.instance.bot_desc_and_commands
      client.say(text: commands, channel: data.channel)
    end

    help do
      title 'Jeoparty Bot'
      desc 'The punniest trivia questions since 1978'

      command 'new game' do
        desc 'Start a new game with the usual 6 categories of 5 questions each.'
      end

      command 'next' do
        desc 'Give the next clue. Remember to answer in the form of a question!'
      end

      command 'what is <answer>' do
        desc 'Try to solve the current clue with <answer>. Other valid triggers are who, what, and when.'
      end

      command 'show my score' do
        desc 'Shows your score in the current game'
      end

      command 'show scoreboard' do
        desc 'Shows all players scores in the current game'
      end

      command 'show leaderboard' do
        desc 'Shows the top 10 players across all games'
      end

      command 'show loserboard' do
        desc 'Shows the bottom 10 players across all games'
      end
    end

    # Format (leader|loser|score)board
    def self.format_board(board)
      players = []
      board.each_with_index do |user, i|
        name = User.get(user[:user_id]).profile
        players << "#{i + 1}. #{name['real']}: #{format_currency(user[:score])}"
      end
      players
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
