provider = require './provider'

module.exports =
  activate: -> provider.loadSyntax()

  getProvider: -> provider
