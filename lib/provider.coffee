fs = require 'fs'
path = require 'path'
pickle = require 'pickle'

emptyLine = /^\s*$/

blockOpenTop = /\[([^.\/][^\/]*)\]/
blockCloseTop = /\[\]/
blockOpenOneLevel = /\[\.\/([^.\/]+)\]/
blockCloseOneLevel = /\[\.\.\/\]/

syntaxFile = /^(yaml|syntax)(_dump_.*-(opt|dbg|oprof))$/

# each moose input file in the project dir could have its own moose app and yaml/syntax associated
# this table points to the app dir for each editor path
appDirs = {}

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

    filePath = path.dirname editor.getPath()
    if filePath in appDirs
      console.log 'loaded:', appDirs[filePath]
      # do immediate completion
    else
      # return a promise that gets fulfilled as soon as the syntax data is loaded
      console.log 'Not yet loaded!'
      dir = @findAppDir filePath
      loadSyntax dir
      appDirs[filePath] = dir

    path = @getCurrentPath(editor, bufferPosition)
    console.log path
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
    head = 0

    loop
      # test the current line for block markers
      if blockOpenTop.test(line)
        path.unshift(blockOpenTop.exec(line)[1])
        break

      if blockOpenOneLevel.test(line)
        if head == 0
          path.unshift(blockOpenOneLevel.exec(line)[1])
        else
          head -= 1

      if blockCloseTop.test(line)
        return null

      if blockCloseOneLevel.test(line)
        head += 1

      # decrement row and fetch line (if we have not found a path we assume we are at the top level)
      row -= 1
      if row < 0
        return null
      line = editor.lineTextForBufferRow(row)

    path

  findAppDir: (appdir) ->
    if not appdir?
      atom.notifications.addError 'File not saved, nowhere to search for MOOSE syntax data.', dismissable: true
      return null

    loop
      # list all files
      for file in fs.readdirSync(appdir)
        match = syntaxFile.exec(file)
        if match and fs.existsSync(path.join appdir, 'yaml'+match[2]) and fs.existsSync(path.join appdir, 'syntax'+match[2])
          console.log 'found: ', appdir, match[2]
          return path: appdir, suffix: match[2]

      # go to parent
      previous_path = appdir
      appdir = path.join appdir, '..'

      if appdir is previous_path
        atom.notifications.addError 'No MOOSE syntax file found. Use peacock to generate.', dismissable: true
        return null

  # unpickle the peacock YAML and syntax files
  loadSyntax: (syntax) ->
    {appPath, appSuffix} = syntax
    fs.readFile path.join(appPath, "syntax#{appSuffix}"), 'utf8', (error, content) =>
      @syntax = content.split('\n') unless error?
      console.log @syntax
      return

    fs.readFile path.join(appPath, "yaml#{appSuffix}"), (error, pickledata) =>
      if error?
        return
      pickle.loads (pickledata), (jsondata) =>
        @yaml = jsondata
        console.log @yaml
      return
