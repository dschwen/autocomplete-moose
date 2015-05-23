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
syntaxWarehouse = {}

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
    filePath = path.dirname request.editor.getPath()

    # lookup application for current input file (cached)
    dir = @findApp filePath

    # check if the syntax is already loaded, currently loading, or not requested yet
    if dir.appPath of syntaxWarehouse
      # syntax is loaded
      return @computeCompletion request, appDirs[filePath]
    else
      # return a promise that gets fulfilled as soon as the syntax data is loaded
      loaded = @loadSyntax dir
      #loaded.then =>
      #

  computeCompletion: (request, dir) ->
    {editor,bufferPosition} = request

    configPath = @getCurrentConfigPath(editor, bufferPosition)
    console.log configPath
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
  getCurrentConfigPath: (editor, position) ->
    row = position.row
    line = editor.lineTextForBufferRow(row).substr(0, position.column)
    configPath = []
    head = 0

    loop
      # test the current line for block markers
      if blockOpenTop.test(line)
        configPath.unshift(blockOpenTop.exec(line)[1])
        break

      if blockOpenOneLevel.test(line)
        if head == 0
          configPath.unshift(blockOpenOneLevel.exec(line)[1])
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

    configPath

  findApp: (filePath) ->
    if not filePath?
      atom.notifications.addError 'File not saved, nowhere to search for MOOSE syntax data.', dismissable: true
      return null

    if filePath of appDirs
      return appDirs[filePath]

    searchPath = filePath
    loop
      # list all files
      for file in fs.readdirSync(searchPath)
        match = syntaxFile.exec(file)
        if match and fs.existsSync(path.join searchPath, 'yaml'+match[2]) and fs.existsSync(path.join searchPath, 'syntax'+match[2])
          console.log 'found app: ', searchPath, match[2]
          appDirs[filePath] = {appPath: searchPath, appSuffix: match[2]}
          return appDirs[filePath]

      # go to parent
      previous_path = searchPath
      searchPath = path.join searchPath, '..'

      if searchPath is previous_path
        atom.notifications.addError 'No MOOSE syntax file found. Use peacock to generate.', dismissable: true
        return null

  # unpickle the peacock YAML and syntax files
  loadSyntax: (syntax) ->
    {appPath, appSuffix} = syntax

    # prepare entry in the syntax warehouse TODO only insert if both components are loaded, otherwise insert promise
    syntaxWarehouse[appPath] = {}

    # load syntax fole for valid block hierarchy
    fs.readFile path.join(appPath, "syntax#{appSuffix}"), 'utf8', (error, content) =>
      syntaxWarehouse[appPath].syntax = content.split('\n') unless error?
      console.log syntaxWarehouse[appPath].syntax
      return

    # load yaml file containing parameters and descriptions
    fs.readFile path.join(appPath, "yaml#{appSuffix}"), (error, pickledata) =>
      if error?
        return
      pickle.loads (pickledata), (jsondata) =>
        syntaxWarehouse[appPath].yaml = jsondata
        console.log syntaxWarehouse[appPath].yaml
      return
