fs = require 'fs-plus'
cp = require 'child_process'
path = require 'path'
yaml = require 'js-yaml'
readline = require 'readline'

Parser = require 'tree-sitter'
Hit = require 'tree-sitter-hit'

parser = new Parser();
parser.setLanguage(Hit);
tree = undefined

emptyLine = /^\s*$/
insideBlockTag = /^\s*\[([^\]#\s]*)$/

parameterCompletion = /^\s*[^\s#=\]]*$/

typeParameter = /^\s*type\s*=\s*[^\s#=\]]*$/
otherParameter = /^\s*([^\s#=\]]+)\s*=\s*('\s*[^\s'#=\]]*(\s?)[^'#=\]]*|[^\s#=\]]*)$/

# new regexp
blockTagContent = /^\s*\[([^\]]*)\]/
blockMultiTagContent = /^\s*\[(.*)/
blockType = /^\s*type\s*=\s*([^#\s]+)/

# legacy regexp
blockOpenTop = /\[([^.\/][^\/]*)\]/
blockCloseTop = /\[\]/
blockOpenOneLevel = /\[\.\/([^.\/]+)\]/
blockCloseOneLevel = /\[\.\.\/\]/

mooseApp = /^(.*)-(opt|dbg|oprof|devel)$/
stdVector = /^std::([^:]+::)?vector<([a-zA-Z0-9_]+)(,\s?std::\1allocator<\2>\s?)?>$/

suggestionIcon = {
  required: '<i class="icon-primitive-square text-error"></i>'
  hasDefault: '<i class="icon-primitive-square text-success"></i>'
  noDefault: '<i class="icon-primitive-dot text-success"></i>'
  type: '<i class="icon-gear keyword"></i>'
  output: '<i class="icon-database text-info"></i>'
}

# each moose input file in the project dir could have its own moose app and
# yaml/syntax associated this table points to the app dir for each editor path
appDirs = {}
syntaxWarehouse = {}

module.exports =
  selector: '.input.moose'
  disableForSelector: '.input.moose .comment'
  inclusionPriority: 1
  excludeLowerPriority: true

  # This will be suggested before the default provider, which has a suggestionPriority of 1.
  suggestionPriority: 2

  # Tell autocomplete to fuzzy filter the results of getSuggestions(). We are
  # still filtering by the first character of the prefix in this provider for
  # efficiency.
  filterSuggestions: true

  # Clear the cache for the app associated with current file.
  # This is made available as an atom command.
  clearCache: ->
    editor = atom.workspace.getActiveTextEditor()
    filePath = path.dirname editor.getPath()
    if filePath of appDirs
      appPath = appDirs[filePath].appPath
      delete appDirs[filePath]
      delete syntaxWarehouse[appPath] if appPath of syntaxWarehouse

  # entry point for the suggestion provider
  # this function will load the syntax files if neccessary before callling
  # the actual completion suggestion builder
  getSuggestions: (request) ->
    filePath = path.dirname request.editor.getPath()

    # lookup application for current input file (cached)
    dir = @findApp filePath
    return [] if not dir?

    # check if the syntax is already loaded, currently loading,
    # or not requested yet
    if dir.appPath of syntaxWarehouse
      w = syntaxWarehouse[dir.appPath]

      # still loading
      if 'promise' of w
        w.promise.then =>
          @prepareCompletion request, w

      # syntax is loaded
      else
        @prepareCompletion request, w

    # return a promise that gets fulfilled as soon as the syntax data is loaded
    else
      loaded = @loadSyntax dir
      loaded.then =>
        # watch executable
        fs.watch dir.appFile, (event, filename) ->
          # force rebuilding of syntax if executable changed
          delete appDirs[filePath]
          delete syntaxWarehouse[dir.appPath]

        # perform completion
        @prepareCompletion request, syntaxWarehouse[dir.appPath]

  prepareCompletion: (request, w) ->
    # asynchronous tree update
    parser.parseTextBuffer(request.editor.getBuffer().buffer, tree).then (newtree) =>
      tree = newtree
      @computeCompletion request, w

  recurseYAMLNode: (node, configPath, matchList) ->
    yamlPath = node.name.substr(1).split '/'

    # no point in recursing deeper
    return if yamlPath.length > configPath.length

    # compare paths if we are at the correct level
    if yamlPath.length == configPath.length
      fuzz = 0
      match = true
      fuzzyOnLast = false

      # TODO compare with specificity depending on '*'
      for configPathElement, index in configPath
        if yamlPath[index] == '*'
          fuzz++
          fuzzyOnLast = true
        else if yamlPath[index] != configPathElement
          match = false
          break
        else
          fuzzyOnLast = false

      # match found
      if match
        matchList.push {
          fuzz: fuzz
          node: node
          fuzzyOnLast: fuzzyOnLast
        }

    # recurse deeper otherwise
    else
      @recurseYAMLNode subNode, configPath, matchList for subNode in node.subblocks or []

  matchYAMLNode: (configPath, w) ->
    # we need to match this to one node in the yaml tree. multiple matches may
    # occur we will later select the most specific match
    matchList = []

    for root in w.yaml
      @recurseYAMLNode root, configPath, matchList

    # no match found
    return {node: null, fuzzyOnLast: null} if matchList.length == 0

    # sort least fuzz first and return minimum fuzz match
    matchList.sort (a, b) ->
      a.fuzz - b.fuzz
    return matchList[0]

  # fetch a list of valid parameters for the current config path
  fetchParameterList: (configPath, explicitType, w) ->
    # parameters cannot exist outside of top level blocks
    return [] if configPath.length == 0
    paramList = []

    # find yaml node that matches the current config path best
    {node, fuzzyOnLast} = @matchYAMLNode configPath, w
    searchNodes = [node]
    # bail out if we are in an invalid path
    return [] unless node?

    # add typed node if either explicitly set in input or if a default is known
    if not explicitType?
      for param in node.parameters or []
        explicitType = param.default if param.name == 'type'

    if explicitType?
      result = @matchYAMLNode @getTypedPath(configPath, explicitType, fuzzyOnLast), w
      if not result?
        return []
      else
        searchNodes.unshift result.node

    for node in searchNodes
      if node?
        paramList.push node.parameters...

    paramList

  # parse current file and gather subblocks of a given top block (Functions,
  # PostProcessors)
  fetchSubBlockList: (blockName, propertyNames, editor) ->
    i = 0
    level = 0
    subBlockList = []
    filterList = ({name: property, re: new RegExp "^\\s*#{property}\\s*=\\s*([^\\s#=\\]]+)$"} for property in propertyNames)

    nlines = editor.getLineCount()

    # find start of selected block
    i++ while i < nlines and editor.lineTextForBufferRow(i).indexOf('[' + blockName + ']') == -1

    # parse contents of subBlock block
    loop
      break if i >= nlines
      line = editor.lineTextForBufferRow i
      break if blockCloseTop.test line

      if blockOpenOneLevel.test line
        if level == 0
          subBlock = {name: blockOpenOneLevel.exec(line)[1], properties: {}}
        level++

      else if blockCloseOneLevel.test(line)
        level--
        if level == 0
          subBlockList.push subBlock

      else if level == 1
        for filter in filterList
          if match = filter.re.exec line
            subBlock.properties[filter.name] = match[1]
            break

      i++

    subBlockList

  # generic completion list builder for subblock names
  computeSubBlockNameCompletion: (blockNames, propertyNames, editor) ->
    completions = []
    for block in blockNames
      for {name, properties} in @fetchSubBlockList block, propertyNames, editor
        doc = []
        for propertyName in propertyNames
          if propertyName of properties
            doc.push properties[propertyName]

        completions.push {
          text: name
          description: doc.join ' '
        }

    completions

  # variable completions
  computeVariableCompletion: (blockNames, editor) ->
    @computeSubBlockNameCompletion blockNames, ['order', 'family'], editor

  # Filename completions
  computeFileNameCompletion: (wildcards, editor) ->
    filePath = path.dirname editor.getPath()
    dir = fs.readdirSync filePath

    completions = []
    for name in dir
      completions.push { text: name }

    completions

  # checks if this is a vector type build the vector cpp_type name for a
  # given single type (checks for gcc and clang variants)
  isVectorOf: (yamlType, type) ->
    (match = stdVector.exec yamlType) and match[2] == type

  # build the suggestion list for parameter values (editor is passed in
  # to build the variable list)
  computeValueCompletion: (param, editor, isQuoted, hasSpace) ->
    completions = []
    singleOK = not hasSpace
    vectorOK = isQuoted or not hasSpace

    hasType = (type) =>
      return (param.cpp_type == type and singleOK) or
             (@isVectorOf(param.cpp_type, type) and vectorOK)

    if (param.cpp_type == 'bool' and singleOK) or
       (@isVectorOf(param.cpp_type, 'bool') and vectorOK)
      completions = [
        {text: 'true'}
        {text: 'false'}
      ]

    else if (param.cpp_type == 'MooseEnum' and singleOK) or
            (param.cpp_type == 'MultiMooseEnum' and vectorOK)
      if param.options?
        for option in param.options.split ' '
          completions.push {
            text: option
          }

    else if hasType 'NonlinearVariableName'
      completions = @computeVariableCompletion ['Variables'], editor

    else if hasType 'AuxVariableName'
      completions = @computeVariableCompletion ['AuxVariables'], editor

    else if hasType 'VariableName'
      completions = @computeVariableCompletion ['Variables', 'AuxVariables'], editor

    else if hasType 'FunctionName'
      completions = @computeSubBlockNameCompletion ['Functions'], ['type'], editor

    else if hasType 'PostprocessorName'
      completions = @computeSubBlockNameCompletion ['Postprocessors'], ['type'], editor

    else if hasType 'UserObjectName'
      completions = @computeSubBlockNameCompletion ['Postprocessors', 'UserObjects'], ['type'], editor

    else if hasType 'VectorPostprocessorName'
      completions = @computeSubBlockNameCompletion ['VectorPostprocessors'], ['type'], editor

    else if (param.cpp_type == 'OutputName' and singleOK) or
            (@isVectorOf(param.cpp_type, 'OutputName') and vectorOK)
      completions.push {text: output, iconHTML: suggestionIcon.output} for output in ['exodus', 'csv', 'console', 'gmv', 'gnuplot', 'nemesis', 'tecplot', 'vtk', 'xda', 'xdr']

    else if (hasType 'FileName') or (hasType 'MeshFileName')
      completions = @computeFileNameCompletion ['*.e'], editor

    completions

  getPrefix: (line) ->
    # Whatever your prefix regex might be
    regex = /[\w0-9_\-.\/\[]+$/

    # Match the regex to the line, and return the match
    line.match(regex)?[0] or ''

  # w contains the syntax applicable to the current file
  computeCompletion: (request, w) ->
    {editor, bufferPosition} = request
    completions = []

    # current line up to the cursor position
    line = editor.getTextInRange([[bufferPosition.row, 0], bufferPosition])
    prefix = @getPrefix line

    # get the type pseudo path (for the yaml)
    {configPath, explicitType} = @getCurrentConfigPath(editor, bufferPosition)

    # for empty [] we suggest blocks
    if @isOpenBracketPair(line)
      # get the postfix (to determine if we need to append a ] or not)
      postLine = editor.getTextInRange([bufferPosition, [bufferPosition.row, bufferPosition.column+1]])
      blockPostfix = if postLine.length > 0 and postLine[0] == ']' then '' else  ']'

      # handle relative paths
      blockPrefix = if configPath.length > 0 then '[./' else '['

      # add block close tag to suggestions
      if configPath.length > 0
        completions.push {
          text: '[../' + blockPostfix
          displayText: '..'
        }

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

          # add to suggestions if it is a new suggestion
          if completion == '*'
            completions.push {
              displayText: '*'
              snippet: blockPrefix + '${1:name}' + blockPostfix
            }
          else if completion != ''
            if (completions.findIndex (c) -> c.displayText == completion) < 0
              completions.push {
                text: blockPrefix + completion + blockPostfix
                displayText: completion
              }

    # complete for type parameter
    else if @isTypeParameter(line)
      # transform into a '<type>' pseudo path
      originalConfigPath = configPath[..]

      # find yaml node that matches the current config path best
      {node, fuzzyOnLast}  = @matchYAMLNode configPath, w
      if fuzzyOnLast
        configPath.pop()
      else
        configPath.push '<type>'

      # find yaml node that matches the current config path best
      {node, fuzzyOnLast}  = @matchYAMLNode configPath, w
      if node?
        # iterate over subblocks and add final yaml path element to suggestions
        for subNode in node.subblocks or []
          completion = (subNode.name.split '/')[-1..][0]
          completions.push {text: completion, description: subNode.description}
      else
        # special case where 'type' is an actual parameter
        # (such as /Executioner/Quadrature)
        # TODO factor out, see below
        paramName = otherParameter.exec(line)[1]
        for param in @fetchParameterList originalConfigPath, explicitType, w
          if param.name == paramName
            completions = @computeValueCompletion param, editor
            break

    # suggest parameters
    else if @isParameterCompletion(line)
      paramNamesFound = []

      # loop over valid parameters
      for param in @fetchParameterList configPath, explicitType, w
        continue if param.name in paramNamesFound
        paramNamesFound.push param.name

        defaultValue = param.default or ''
        defaultValue = "'#{defaultValue}'" if defaultValue.indexOf(' ') >= 0

        if param.cpp_type == 'bool'
          defaultValue = 'false' if defaultValue == '0'
          defaultValue = 'true'  if defaultValue == '1'

        icon =
          if param.name == 'type'
            suggestionIcon['type']
          else if param.required == 'Yes'
            suggestionIcon['required']
          else
            if param.default != ''
              suggestionIcon['hasDefault']
            else
              suggestionIcon['noDefault']

        completions.push {
          displayText: param.name
          snippet: param.name + ' = ${1:' + defaultValue  + '}'
          description: param.description
          iconHTML: icon
        }

    # complete for other parameter values
    else if !!(match = otherParameter.exec(line))
      # TODO factor out, see above
      paramName = match[1]
      isQuoted = match[2][0] == "'"
      hasSpace = !!match[3]
      for param in @fetchParameterList configPath, explicitType, w
        if param.name == paramName
          completions = @computeValueCompletion param, editor, isQuoted, hasSpace
          break

    # set the custom prefix
    for completion in completions
      completion.replacementPrefix = prefix

    completions

  onDidInsertSuggestion: ({editor, suggestion}) ->
    setTimeout(@triggerAutocomplete.bind(this, editor), 1) if suggestion.type is 'property'

  triggerAutocomplete: (editor) ->
    atom.commands.dispatch(atom.views.getView(editor), 'autocomplete-plus:activate', {activatedManually: false})

  # check if the current line is empty (in that case we complete for parameter
  # names or block names)
  isLineEmpty: (editor, position) ->
    emptyLine.test(editor.lineTextForBufferRow(position.row))

  # check if there is an square bracket pair around the cursor
  isOpenBracketPair: (line) ->
    return insideBlockTag.test line

  # check if the current line is a type parameter
  isTypeParameter: (line) ->
    typeParameter.test line

  # check if the current line is a type parameter
  isParameterCompletion: (line) ->
    parameterCompletion.test line

  # drop all comments from a given input file line
  dropComment: (line) ->
    cpos = line.indexOf('#')
    if cpos >= 0
      line = line.substr(cpos)
    line

  # add the /Type (or /<type>/Type for top level blocks) pseudo path
  # if we are inside a typed block
  getTypedPath: (configPath, type, fuzzyOnLast) ->
    typedConfigPath = configPath[..]

    if type? and type != ''
      #if configPath.length > 1
      if fuzzyOnLast
        typedConfigPath[configPath.length-1] = type
      else
        typedConfigPath.push ['<type>', type]...
      #else
      #  typedConfigPath.push type

    typedConfigPath

  # determine the active input file path at the current position
  getCurrentConfigPath: (editor, position, addTypePath) ->
    row = position.row
    line = editor.lineTextForBufferRow(row).substr(0, position.column)
    configPath = []
    types = []

    recurseCurrentConfigPath = (node, sourcePath = []) ->
      for c in node.children
        if c.type != 'top_block' && c.type != 'block'
          continue

        # console.log  c.text
        # check if we are inside a block or top_block
        cs = c.startPosition
        ce = c.endPosition
        console.log cs, ce, position

        # outside row range
        if position.row < cs.row || position.row > ce.row
          continue

        # in starting row but before starting column
        if position.row == cs.row && position.column < cs.column
          continue

        # in ending row but after ending column
        if position.row == ce.row && position.column >= ce.column
          continue

        # if the block does not contain a valid path subnode we give up
        if c.children.length < 2 || c.children[1].type != 'block_path'
          return null

        name = c.children[1].text
        sourcePath.push(name.replace(/^\.\//, ''))
        return recurseCurrentConfigPath c, sourcePath

      return [node, sourcePath]


    [node, sourcePath] =recurseCurrentConfigPath tree.rootNode
    ret = {configPath: sourcePath, explicitType: null}

    # found a block we can check for a type parameter
    if node != null
      for c in node.children
        if c.type != 'parameter_definition' || c.children.length < 3 || c.children[0].text != 'type'
          continue
        ret.explicitType = c.children[2].text
        break

    # return value
    ret

  findApp: (filePath) ->
    if not filePath?
      atom.notifications.addError 'File not saved, nowhere to search for MOOSE syntax data.', dismissable: true
      return null

    if filePath of appDirs
      return appDirs[filePath]

    searchPath = filePath
    matches = []
    loop
      # list all files
      for file in fs.readdirSync(searchPath)
        match = mooseApp.exec(file)
        if match
          fileWithPath = path.join searchPath, file
          continue if not fs.isExecutableSync fileWithPath
          matches.push {
            appPath: searchPath
            appName: match[1]
            appFile: fileWithPath
            appDate: fs.statSync(fileWithPath).mtime.getTime()
          }

      if matches.length > 0
        # return newest application
        matches.sort (a, b) ->
          a.appDate < b.appDate

        appDirs[filePath] = matches[0]
        return appDirs[filePath]

      # go to parent
      previous_path = searchPath
      searchPath = path.join searchPath, '..'

      if searchPath is previous_path
        # no executable found, let's check the fallback path
        fallbackMooseDir = atom.config.get "autocomplete-moose.fallbackMooseDir"
        if fallbackMooseDir != '' and filePath != fallbackMooseDir
          return @findApp fallbackMooseDir

        # otherwise pop up an error notification (if not disabled) end give up
        atom.notifications.addError 'No MOOSE application executable found.', dismissable: true \
          unless  atom.config.get "autocomplete-moose.ignoreMooseNotFoundError"
        return null

  # rebuild syntax
  rebuildSyntax: (app, cacheFile, w) ->
    {appFile} = app

    # open notification about syntax generation
    workingNotification = atom.notifications.addInfo 'Rebuilding MOOSE syntax data.', {dismissable: true}

    # rebuild the syntax by running moose with --syntax and --yaml
    mooseYAML = new Promise (resolve, reject) ->
      yamlData = ''

      args = ['--yaml']
      if atom.config.get "autocomplete-moose.allowTestObjects"
        args.push '--allow-test-objects'
      moose = cp.spawn appFile, args, {stdio:['pipe','pipe','ignore']}

      moose.stdout.on 'data', (data) ->
        yamlData += data

      moose.on 'close',  (code, signal) ->
        if code is 0
          resolve yamlData
        else
          reject {code: code, output: yamlData, appFile: appFile}

    .then (result) ->
      beginMarker = '**START YAML DATA**\n'
      endMarker = '**END YAML DATA**\n'
      begin = result.indexOf beginMarker
      end= result.lastIndexOf endMarker

      throw 'markers not found' if begin < 0 or end < begin

      yaml.safeLoad result[begin+beginMarker.length..end-1]

    mooseSyntax = new Promise (resolve, reject) ->
      cp.execFile appFile, ['--syntax'], (error, stdout, stderr) ->
        reject error if error?

        lines = stdout.toString().split('\n')
        begin = lines.indexOf '**START SYNTAX DATA**'
        end = lines.indexOf '**END SYNTAX DATA**'

        reject('marker') if begin < 0 or end <= begin
        resolve lines[begin+1..end-1]

    # promise that is fulfilled when all processes are done
    loadFiles = Promise.all [
      mooseSyntax
      mooseYAML
    ]

    loadFiles.catch (error) ->
      workingNotification.dismiss()
      atom.notifications.addError 'Failed to build MOOSE syntax data.', dismissable: true

    finishSyntaxSetup = loadFiles.then (result) ->
      workingNotification.dismiss()
      delete w.promise
      w.syntax = result[0]
      w.yaml   = result[1]
      w

    # we return finishSyntaxSetup, but we chain a promise onto it to write out
    # the cache file
    finishSyntaxSetup.then (result) ->
      fs.writeFile cacheFile, JSON.stringify(result), ->

    w.promise = finishSyntaxSetup

  # fetch YAML and syntax data
  loadSyntax: (app) ->
    {appPath, appName, appFile, appDate} = app

    # we store syntax data here:
    cacheDir = path.join __dirname, '..', 'cache'
    fs.makeTreeSync cacheDir
    cacheFile = path.join cacheDir, "#{appName}.json"

    # prepare entry in the syntax warehouse
    w = syntaxWarehouse[appPath] = {}

    # see if the cache file exists
    if fs.existsSync cacheFile
      cacheDate = fs.statSync(cacheFile).mtime.getTime()

      # if the cacheFile is newer than the app compile date we use the cache
      if cacheDate > appDate
        # return chained promises to load and parse the cached syntax
        loadCache = new Promise (resolve, reject) ->
          fs.readFile cacheFile, 'utf8', (error, content) ->
            reject() if error?
            resolve content

        .then JSON.parse

        .then (result) ->
          delete w.promise
          w.yaml = result.yaml
          w.syntax = result.syntax

        .catch ->
          # TODO: rebuild syntax if loading the cache fails
          atom.notifications.addError 'Failed to load cached syntax.', dismissable: true
          delete syntaxWarehouse[appPath]
          fs.unlink(cacheFile)

        w.promise = loadCache
        return loadCache

    @rebuildSyntax app, cacheFile, w
