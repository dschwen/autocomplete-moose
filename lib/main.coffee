provider = require './provider'

module.exports =
  config:
    ignoreMooseNotFoundError:
      type: 'boolean'
      default: false
      description: 'Suppress error popups if no MOOSE executable is found.'
    allowTestObjects:
      type: 'boolean'
      default: true
      description: 'Show test objects in the suggestion list.'
    fallbackMooseDir:
      type: 'string'
      default: ''
      description: 'If no MOOSE executable is found in or above the current directory, search heare instead.'

  activate: (state) ->
    atom.commands.add 'atom-workspace', 'autocomplete-moose:clear-cache', => provider.clearCache()

  getProvider: -> provider
