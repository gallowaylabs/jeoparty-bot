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

SlackRubyBot::Client.logger.level = Logger::WARN

class JeopartyBot < SlackRubyBot::Bot
  match /^next\s*($|answer|clue)/ do |client, data, match|
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

  match /^(what|whats|where|wheres|who|whos) /i do |client, data, match|
    verdict = Game.in(data.channel).attempt_answer(data.user, data.text)

    if verdict[:duplicate]
      client.say(text: "Only one guess per clue is allowed <@#{data.user}>!", channel: data.channel)
    elsif verdict[:correct]
      client.say(text: "That is the correct answer <@#{data.user}> :tada: Your score is now #{verdict[:score]}",
                 channel: data.channel)
    elsif !verdict[:clue_gone] && !verdict[:correct]
      client.say(text: "Sorry <@#{data.user}>, that is incorrect. Your score is now #{verdict[:score]}",
                 channel: data.channel)
    end
  end

  match /^show\s*(my)?\s*score\s*$/ do |client, data, match|
    score = User.get(data.user).score(data.channel)
    client.say(text: "<@#{data.user}>, your score is #{score}", channel: data.channel)
  end

  match /^(new|start) game/ do |client, data, match|
    clue_count = Game.in(data.channel).remaining_clue_count

    # Only start a new game if the previous game is over
    if clue_count.nil? || clue_count == 0
      category_names = Game.in(data.channel).new_game

      client.say(text: "*Starting a new game!* The categories today are:\n #{category_names.join("\n")}",
                 channel: data.channel)
    else
      client.say(text: "Not yet! There are still #{clue_count} clues remaining", channel: data.channel)
    end
  end

  match /^shuffle categories/ do |client, data, match|
    if User.get(data.user).is_moderator?
      category_names = Game.in(data.channel).new_game

      client.say(text: "*Starting a new game!* The categories today are:\n #{category_names.join("\n")}",
                 channel: data.channel)
    end
  end

  match /^clues remaining/ do |client, data, match|
    clue_count = Game.in(data.channel).remaining_clue_count
    client.say(text: "There are #{clue_count} clues remaining", channel: data.channel)
  end

  match /^show scoreboard/ do |client, data, match|
    players = format_board(Game.in(data.channel).scoreboard)
    unless players.empty?
      client.say(text: "The scores for this game are:\n> #{players.join("\n>")}", channel: data.channel)
    end
  end

  match /^show leaderboard/ do |client, data, match|
    players = format_board(Game.in(data.channel).leaderboard)
    client.say(text: "The lowest scoring players across all games are\n> #{players.join("\n>")}", channel: data.channel)
  end

  match /^show loserboard/ do |client, data, match|
    players = format_board(Game.in(data.channel).leaderboard(true))
    client.say(text: "The highest scoring players across all games are\n> #{players.join("\n>")}", channel: data.channel)
  end

  match /^judges (?<verb>correct|incorrect) \<@(?<user>[\w\d]*)\>\s* (?<clue>[\d]*)/i do |client, data, match|
    if !match[:verb].nil? && !match[:user].nil? && !match[:clue].nil? && User.get(data.user).is_moderator?
      clue = Game.in(data.channel).get_clue(match[:clue])
      puts clue
      unless clue.nil?
        # Double value to make up for the lost points
        new_score = User.get(match[:user]).update_score(data.channel, clue['value'].to_i * 2, match[:verb].downcase == 'correct')
        client.say(text: "<@#{match[:user]}>, the judges reviewed your answer and found that you were #{match[:verb].downcase}. Your score is now #{new_score}",
                   channel: data.channel)
      end
    end
  end

  command 'build category cache' do |client, data, match|
    if User.get(data.user).is_moderator?
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

  match /^use token (?<token>[\w\d]*)\s*/ do |client, data, match|
    if !match[:token].nil? && match[:token] == ENV['GLOBAL_MOD_TOKEN']
      User.get(data.user).make_moderator(true)
      client.say(text: 'You are now a global moderator. Add other moderators with `add moderator @name`',
                 channel: data.channel)
    end
  end

  match /^add moderator \<@(?<user>[\w\d]*)\>\s*/ do |client, data, match|
    if User.get(data.user).is_moderator?(true) && !match[:user].nil?
      User.get(match[:user]).make_moderator
      client.say(text: "<@#{match[:user]}> is now a moderator", channel: data.channel)
    end
  end

  # Format (leader|loser|score)board
  def self.format_board(board)
    players = []
    board.each_with_index do |user, i|
      name = User.get(user[:user_id]).profile
      players << "#{i + 1}. #{name['real']}: #{user[:score]}"
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

  bot1 = SlackRubyBot::Server.new(token: ENV['SLACK_API_TOKEN'], aliases: ['tb'])
  bot1.start_async
end
