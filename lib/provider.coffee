fs = require 'fs'
path = require 'path'
pickle = require 'pickle'

emptyLine = /^\s*$/
insideBlockTag = /^\s*\[([^\]#\s]*)$/

parameterCompletion = /^\s*[^\s#=\]]*$/

variableParameter = /^\s*variable\s*=\s*$/ # TODO parse variables
typeParameter = /^\s*type\s*=\s*$/
otherParameter = /^\s*([^\s#=\]]+)\s*=\s*[^\s#=\]]*$/

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
        matchList.push {
          fuzz: fuzz
          node: node
        }

    # recurse deeper otherwise
    else
      @recurseYAMLNode subNode, configPath, matchList for subNode in node.subblocks or []

  matchYAMLNode: (configPath, w) ->
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
    return matchList[0].node

  # fetch a list of valis parameters for the current config path
  fetchParameterList: (configPath, explicitType, w) ->
    # parameters cannot exist outside of top level blocks
    return [] if configPath.length == 0

    paramList = []

    # find yaml node that matches the current config path best
    bareNode = @matchYAMLNode configPath, w
    searchNodes = [bareNode]

    # add typed node if either explicitly set in input or if a default is known
    if not explicitType?
      for param in bareNode.parameters or []
        explicitType = param.default if param.name == 'type'
    if explicitType?
      searchNodes.push @matchYAMLNode @getTypedPath(configPath, explicitType), w

    for node in searchNodes
      if node?
        paramList.push node.parameters...

    console.log paramList
    paramList

  # build the suggestion list for parameter values
  computeValueCompletion: (param) ->
    completions = []

    if param.cpp_type == 'bool'
      completions = [
        {text: 'true'}
        {text: 'false'}
      ]
    else if param.cpp_type == 'MooseEnum'
      for option in param.options.split ' '
        completions.push {
          text: option
        }

    completions

  # w contains the syntax applicable to the current file
  computeCompletion: (request, w) ->
    {editor,bufferPosition} = request
    completions = []
    line = @lineToCursor editor, bufferPosition

    # get the type pseudo path (for the yaml)
    {configPath, explicitType} = @getCurrentConfigPath(editor, bufferPosition)

    # for empty [] we suggest blocks
    if @isOpenBracketPair(line)
      # get the true replacementPrefix (autocomplete does not see the "./")
      givenPrefix = insideBlockTag.exec(line)[1]

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
          completion = suggestion[configPath.length]

          # handle the prefix correctly
          prefix = ''
          if configPath.length > 0
            if givenPrefix.substr(0, 1) != '.'
              prefix = './'
            else if givenPrefix.substr(0, 2) != './'
              prefix = '/'

          # add to suggestions if it is a new suggestion
          if completion == '*'
            completions.push {
              displayText: prefix + '*'
              snippet: prefix + '${1:name}'
            }
          else
            completions.push {text: prefix + completion} unless completion == ''

    # suggest parameters
    else if @isParameterCompletion(line)
      # loop over valid parameters
      for param in @fetchParameterList configPath, explicitType, w
        defaultValue = param.default or ''

        if param.cpp_type == 'bool'
          defaultValue = 'false' if defaultValue == '0'
          defaultValue = 'true'  if defaultValue == '1'

        completions.push {
          displayText: param.name
          snippet: param.name + ' = ${1:' + defaultValue  + '}'
          description: param.description
          type: 'property'
        }

    # complete for type parameter
    else if @isTypeParameter(line)
      # transform into a '<type>' pseudo path
      if configPath.length > 1
        configPath.pop()
      else
        configPath.push '<type>'

      # find yaml node that matches the current config path best
      node = @matchYAMLNode configPath, w
      if node?
        # iterate over subblocks and add final yaml path element to suggestions
        for subNode in node.subblocks or []
          completion = (subNode.name.split '/')[-1..][0]
          completions.push {text: completion}

    # complete for variable parameter
    else if @isVariableParameter(line)
      console.log 'TODO: variable name cpompletion'

    # complete for other parameter values
    else if @isOtherParameter(line)
      paramName = otherParameter.exec(line)[1]
      for param in @fetchParameterList configPath, explicitType, w
        if param.name == paramName
          completions = @computeValueCompletion param
          break

    completions

  onDidInsertSuggestion: ({editor, suggestion}) ->
    setTimeout(@triggerAutocomplete.bind(this, editor), 1) if suggestion.type is 'property'

  triggerAutocomplete: (editor) ->
    atom.commands.dispatch(atom.views.getView(editor), 'autocomplete-plus:activate', {activatedManually: false})

  # current line up to the cursor position
  lineToCursor: (editor, position) ->
    line = editor.lineTextForBufferRow position.row
    line.substr 0, position.column

  # check if the current line is empty (in that case we complete for parameter names or block names)
  isLineEmpty: (editor, position) ->
    emptyLine.test(editor.lineTextForBufferRow(position.row))

  # check if there is an square bracket pair around the cursor
  isOpenBracketPair: (line) ->
    return insideBlockTag.test line

  # check if the current line is a type parameter
  isTypeParameter: (line) ->
    typeParameter.test line

  # check if the current line is a type parameter
  isVariableParameter: (line) ->
    variableParameter.test line

  # TODO check if we are after the equal sign in a parameter line
  isOtherParameter: (line) ->
    otherParameter.test line

  # check if the current line is a type parameter
  isParameterCompletion: (line) ->
    parameterCompletion.test line

  # drop all comments from a given input file line
  dropComment: (line) ->
    cpos = line.indexOf('#')
    if cpos >= 0
      line = line.substr(cpos)
    line

  # add the /Type (or /<type>/Type for top level blocks) pseudo path if we are inside a typed block
  getTypedPath: (configPath, type) ->
    if type?
      if configPath.length > 1
        configPath[configPath.length-1] = type
      else
        configPath.push ['<type>', type]...

    configPath

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
        return {configPath: []}

      if blockCloseOneLevel.test(line)
        level += 1

      # test for a type parameter
      if blockType.test(line) and level == 0 and type == null
        type = blockType.exec(line)[1]


      # decrement row and fetch line (if we have not found a path we assume we are at the top level)
      row -= 1
      if row < 0
        return {configPath: []}
      line = editor.lineTextForBufferRow(row)

    {configPath: configPath, explicitType: type}

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
