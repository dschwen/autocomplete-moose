provider = require './provider'

module.exports =
  config:
    ignoreMooseNotFoundError:
      type: 'boolean'
      default: false

  getProvider: -> provider
