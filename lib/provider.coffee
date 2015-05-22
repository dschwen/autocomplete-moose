fs = require 'fs'
path = require 'path'

emptyLine = /^\s*$/

blockOpenTop = '/\[[^.\/][^\/]*\]'
blockCloseTop = '/\[\]'
blockOpenOneLevel = '/\[\.\/[^.\/]+\]'
blockCloseOneLevel = '/\[\.\.\/\]'

module.exports =
  selector: '.input.moose'
  disableForSelector: '.input.moose .comment, .input.moose .string'
  inclusionPriority: 1
  excludeLowerPriority: true

  # Tell autocomplete to fuzzy filter the results of getSuggestions(). We are
  # still filtering by the first character of the prefix in this provider for
  # efficiency.
  filterSuggestions: true

  getSuggestions: (request) ->
    console.log request
    {editor,bufferPosition} = request

    path = @getCurrentPath(editor, bufferPosition)
    completions = null

    if @isLineEmpty(editor, bufferPosition)
      completions = [
        {text: '[Kernels]'}
        {text: '[Materials]'}
      ]

    completions

  onDidInsertSuggestion: ({editor, suggestion}) ->
    setTimeout(@triggerAutocomplete.bind(this, editor), 1) if suggestion.type is 'property'

  triggerAutocomplete: (editor) ->
    atom.commands.dispatch(atom.views.getView(editor), 'autocomplete-plus:activate', {activatedManually: false})

  # check if the current line is empty (in that case we complete for parameter names or block names)
  isLineEmpty: (editor, position) ->
    emptyLine.test(editor.lineTextForBufferRow(position.row))

  # drop all comments from a given input file line
  dropComment: (line) ->
    cpos = line.indexOf('#')
    if cpos >= 0
      line = line.substr(cpos)
    line

  # determine the active input file path at the current position
  getCurrentPath: (editor, position) ->
    row = position.row
    line = editor.lineTextForBufferRow(row).substr(0, position.column)
    path = []

    while true
      # test the current line for block markers

      # decrement row and fetch line (if we have not found a path we assume we are at the top level)
      row -= 1
      if row < 0
        return ''
      line = editor.lineTextForBufferRow(row)

    null
