# Jeoparty Bot
(sic)

Yet another Jeopardy bot for Slack powered by the jService API. Uses the Slack Realtime API to facilitate more
 convenient interaction between players and the bot. 

## Requirements
* A Slack bot integration user
* A free tier Heroku account or,
* Any server that runs Ruby 2.3.3 and a little Ruby know-how

## Installation

1. Set up a Slack bot integration at https://slack.com/services/new/bot. Make sure to pick a nice name, such as 'trebek'. 
Bonus points for using an icon other than '?'
2. Copy the API token for the bot you just created
3. Click this magic button to deploy this project to Heroku (TODO). You will be prompted to set a few simple parameters. 
    - Alternatively, clone this repository, set up a Ruby Heroku app with Heroku Redis and deploy the bot there.
    - Make sure to set up the config variables in .env.example in your Heroku app's settings screen.

## First Time Setup
Once the bot is running, start a direct message with it. During the app deployment process, a GLOBAL_MOD_TOKEN was
generated for you. Message the bot `use token <TOKEN>` in order to establish yourself as a global moderator. Global 
moderators may add other moderators (more on that soon) and may never be removed short of purging the Redis database, 
so be careful about distributing the GLOBAL_MOD_TOKEN.

Next, message the bot `build cache`, which builds all necessary caches for the bot to ask questions.

Finally, you may add other moderators with `add moderator @name`. Be sure to use an `@` when mentioning the user's name.

## Usage
Invite the bot to any channel, public or private, via `/invite <@BotName>` and begin a game by saying `start game`. 
Due to the use of the real-time API, no trigger word or forward slash is required for _most_ commands. Advance to the
first (next) clue with `next clue`, or simply `next`, and answer in the form of a question starting with "who", "what", 
"when", or "where". For additional commands, say `@BotName help` (this is one of those rare commands that requires the 
bot name to be used first).

## Credits & Acknowledgements

* Steve Ottenad for building jService, the clue database that powers this bot.
* Guillermo Esteves for writing trebekbot, a webhook-based Jeopardy bot that project was inspired by.
* The developers of the slack-ruby-bot gem

## License
MIT. See LICENSE for the full text. 
