# Jeoparty Bot!
(sic)

Yet another bot for Slack that asks Jeopardy-like trivia questions. Uses the Slack Realtime API to facilitate more
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

## Next Steps
See the GitHub Wiki for more information about what to do post-installation. 
https://github.com/esbdotio/jeoparty-bot/wiki

## Credits & Acknowledgements

* Steve Ottenad for building jService, the clue database that powers this bot.
* Guillermo Esteves for writing trebekbot, a webhook-based Jeopardy bot that project was inspired by.
* The developers of the slack-ruby-bot gem

## License
MIT. See LICENSE for the full text. 
