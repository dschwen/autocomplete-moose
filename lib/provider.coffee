fs = require 'fs'
path = require 'path'
pickle = require 'pickle'

emptyLine = /^\s*$/
emptyType = /^\s*type\s*=\s*$/

blockOpenTop = /\[([^.\/][^\/]*)\]/
blockCloseTop = /\[\]/
blockOpenOneLevel = /\[\.\/([^.\/]+)\]/
blockCloseOneLevel = /\[\.\.\/\]/
blockType = /^\s*type\s*=\s*([^#\s]+)/

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

  # entry point for the suggestion provider
  # this function will load the syntax files if neccessary before callling
  # the actual completion suggestion builder
  getSuggestions: (request) ->
    filePath = path.dirname request.editor.getPath()

    # lookup application for current input file (cached)
    dir = @findApp filePath

    # check if the syntax is already loaded, currently loading, or not requested yet
    if dir.appPath of syntaxWarehouse
      w = syntaxWarehouse[dir.appPath]

      # still loading
      if 'promise' of w
        w.promise.then =>
          @computeCompletion request, w

      # syntax is loaded
      else
        @computeCompletion request, w

    # return a promise that gets fulfilled as soon as the syntax data is loaded
    else
      loaded = @loadSyntax dir
      loaded.then =>
        @computeCompletion request, syntaxWarehouse[dir.appPath]

  recurseYAMLNode: (node, configPath, matchList) ->
      yamlPath = node.name.substr(1).split '/'

      # no point in recursing deeper
      return if yamlPath.length > configPath.length

      # compare paths if we are at the correct level
      if yamlPath.length == configPath.length
        fuzz = 0
        match = true
        # TODO compare with specificity depending on '*'
        for configPathElement, index in configPath
          if yamlPath[index] == '*'
            fuzz++
          else if yamlPath[index] != configPathElement
            match = false
            break

        # match found
        if match
          matchList.push {fuzz: fuzz, node: node}

      # recurse deeper otherwise
      else
        @recurseYAMLNode subNode, configPath, matchList for subNode in node.subblocks or []

  matchYAMLNode: (node, configPath, w) ->
    # we need to match this to one node in the yaml tree. multiple matches may occur
    # we will later select the most specific match
    matchList = []
    for root in w.yaml
      @recurseYAMLNode root, configPath, matchList

    # no match found
    return null if matchList.length == 0

    # sort least fuzz first and return minimum fuzz match
    matchList.sort (a, b) ->
      a.fuzz > b.fuzz
    return matchList[0]

  # build the suggestion list
  # w contains the syntax applicable to the current file
  computeCompletion: (request, w) ->
    {editor,bufferPosition} = request
    completions = []

    # for empty lines we suggest parameters
    if @isLineEmpty(editor, bufferPosition)
      # get the type pseudo path (for the yaml)
      configPath = @getCurrentConfigPath(editor, bufferPosition, true)

      # parameters cannot exist outside of top level blocks
      return null if configPath.length == 0

      # find yaml node that matches the current config path best
      node = @matchYAMLNode root, configPath, w
      if node?
        console.log 'found', node
      else
        console.log 'not found', w.yaml

    else if @isOpenBracketPair(editor, bufferPosition)
      # ignore type (for the syntax)
      configPath = @getCurrentConfigPath(editor, bufferPosition, false)

      # go over all entries in the syntax file to find a match
      for suggestionText in w.syntax
        suggestion = suggestionText.split '/'

        # check if the suggestion is a match
        match = true
        if suggestion.length <= configPath.length
          match = false
        else
          for configPathElement, index in configPath
            if suggestion[index] != '*' and suggestion[index] != configPathElement
              match = false
              break

        if match
          completion = (if configPath.length > 0 then './' else '') +
                       suggestion[configPath.length]

          # add to suggestions if it is a new suggestion
          if completion not in completions
            completions.push {text: completion}

    else if @isEmptyTypeParameter(editor, bufferPosition)
      # ignore type (for the syntax)
      configPath = @getCurrentConfigPath(editor, bufferPosition, false)

      # transform into a '<type>' pseudo path
      if configPath.length > 1
        configPath.pop()
      else
        configPath.push '<type>'

      # find yaml node that matches the current config path best
      node = @matchYAMLNode root, configPath, w
      if node?
        # iterate over subblocks and add final yaml path element to suggestions
        console.log 'TODO'

    completions

  onDidInsertSuggestion: ({editor, suggestion}) ->
    setTimeout(@triggerAutocomplete.bind(this, editor), 1) if suggestion.type is 'property'

  triggerAutocomplete: (editor) ->
    atom.commands.dispatch(atom.views.getView(editor), 'autocomplete-plus:activate', {activatedManually: false})

  # check if the current line is empty (in that case we complete for parameter names or block names)
  isLineEmpty: (editor, position) ->
    emptyLine.test(editor.lineTextForBufferRow(position.row))

  # check if there is an square bracket pair around the cursor
  isOpenBracketPair: (editor, position) ->
    if position.column < 1
      return false
    line = editor.lineTextForBufferRow position.row
    return line.substr(position.column-1, 2) == '[]'

  # TODO check if we are after the equal sign in a parameter line
  isParameterDeclartion: (editor, position) ->
    return false

  # check if the current line is empty (in that case we complete for parameter names or block names)
  isEmptyTypeParameter: (editor, position) ->
    emptyType.test(editor.lineTextForBufferRow(position.row))

  # drop all comments from a given input file line
  dropComment: (line) ->
    cpos = line.indexOf('#')
    if cpos >= 0
      line = line.substr(cpos)
    line

  # determine the active input file path at the current position
  getCurrentConfigPath: (editor, position, addTypePath) ->
    row = position.row
    line = editor.lineTextForBufferRow(row).substr(0, position.column)
    configPath = []
    type = null
    level = 0

    loop
      # test the current line for block markers
      if blockOpenTop.test(line)
        configPath.unshift(blockOpenTop.exec(line)[1])
        break

      if blockOpenOneLevel.test(line)
        if level == 0
          configPath.unshift(blockOpenOneLevel.exec(line)[1])
        else
          level -= 1

      if blockCloseTop.test(line)
        return []

      if blockCloseOneLevel.test(line)
        level += 1

      # test for a type parameter
      if blockType.test(line) and level == 0 and type == null
        type = blockType.exec(line)[1]


      # decrement row and fetch line (if we have not found a path we assume we are at the top level)
      row -= 1
      if row < 0
        return []
      line = editor.lineTextForBufferRow(row)

    # add the /Type (or /<type>/Type for top level blocks) pseudo path if we are inside a typed block
    if type? and addTypePath
      if configPath.length > 1
        configPath[configPath.length-1] = type
      else
        configPath.push ['<type>', type]...

    console.log configPath
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
  loadSyntax: (app) ->
    {appPath, appSuffix} = app

    # prepare entry in the syntax warehouse TODO only insert if both components are loaded, otherwise insert promise
    w = syntaxWarehouse[appPath] = {}

    # load syntax file for valid block hierarchy
    syntaxPromise = new Promise (resolve, reject) ->
      fs.readFile path.join(appPath, "syntax#{appSuffix}"), 'utf8', (error, content) ->
        reject() if errror?
        resolve content.split('\n')

    # load yaml file containing parameters and descriptions
    yamlPromise = new Promise (resolve, reject) ->
      fs.readFile path.join(appPath, "yaml#{appSuffix}"), (error, pickledata) ->
        reject if error?
        pickle.loads (pickledata), (jsondata) ->
          resolve jsondata

    # promise that is fulfilled when all files are loaded
    loadFiles = Promise.all [
      syntaxPromise
      yamlPromise
    ]

    finishSyntaxSetup = loadFiles.then (result) ->
      delete w.promise
      w.syntax = result[0]
      w.yaml   = result[1]

    w.promise = finishSyntaxSetup
