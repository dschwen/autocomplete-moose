provider = require './provider'

module.exports =
  config:
    ignoreMooseNotFoundError:
      type: 'boolean'
      default: false
    fallbackMooseDir:
      type: 'string'
      default: ''

  activate: (state) ->
    atom.commands.add 'atom-workspace', 'autocomplete-moose:clear-cache', => provider.clearCache()

  getProvider: -> provider
