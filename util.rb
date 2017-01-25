module Jeoparty
  # A bunch of random stuff needed in >1 class
  class Util

    # Removes ::skin-tone and any other modifiers that follow that spec
    def self.base_emoji(emoji)
      emoji.gsub(/::[\w-]*/, '')
    end

    # Format number as currency (i.e. with commas and a dollar sign)
    def self.format_currency(input)
      formatted = input.to_s.reverse.gsub(%r{([0-9]{3}(?=([0-9])))}, "\\1,").reverse
      formatted[0] == '-' ? '-$' + formatted[1..-1] : '$' + formatted
    end
  end
end
