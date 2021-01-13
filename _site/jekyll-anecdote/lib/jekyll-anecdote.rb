require "jekyll"

# Requires CSS like this:

# .tooltip {
#   cursor: pointer;
# }
#
# .tooltip span {
#   display: none;
#   background-color: lightyellow;
#   border: solid 1px black;
#   border-radius: 4px;
#   margin-top: -20px;
#   margin-left: -20px;
#   padding: 2px 3px;
# }
#
# .tooltip:hover span {
#   display: inline-block;
#   position: absolute;
# }

class AnecdoteTag < Liquid::Tag
  def initialize(tag_name, text, tokens)
    super
    @text = text
  end

  def render(context)
    /([^|]+)\|(.+)/.match @text.strip
    "<sup class=\"tooltip\">[#{$1}]<span>#{$2}</span></sup>"
  end

  Liquid::Template.register_tag "anecdote", self
end