provider = require './provider'

module.exports =
  config:
    ignoreMooseNotFoundError:
      type: 'boolean'
      default: false
    fallbackMooseDir:
      type: 'string'
      default: ''

  getProvider: -> provider
