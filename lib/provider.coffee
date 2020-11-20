# coffeelint: disable=max_line_length

fs = require 'fs-plus'
cp = require 'child_process'
path = require 'path'
readline = require 'readline'

Parser = require 'web-tree-sitter'

parser = undefined
tree = undefined

# while the Parser is initializing and loading the language, we block its use
Parser.init().then () ->
  Parser.Language.load(path.join __dirname,'./tree-sitter-hit.wasm').then (lang) ->
    parser = new Parser()
    parser.setLanguage(lang)

insideBlockTag = /^\s*\[([^\]#\s]*)$/

parameterCompletion = /^\s*[^\s#=\]]*$/

typeParameter = /^\s*type\s*=\s*[^\s#=\]]*$/
otherParameter = /^\s*([^\s#=\]]+)\s*=\s*('\s*[^\s'#=\]]*(\s?)[^'#=\]]*|[^\s#=\]]*)$/

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
# json/syntax associated this table points to the app dir for each editor path
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

  # include parameters marked as deprecated in the suggestions
  hideDeprecatedParams: null

  # offline syntax dump
  offlineSyntax: null

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
    if @offlineSyntax
      dir = {appPath: @offlineSyntax, appName: null, appFile: null, appDate: null, appWSL: null}
    else
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
        # watch executable (unless it's WSL)
        if dir.appFile? and not dir.appWSL?
          fs.watch dir.appFile, (event, filename) ->
            # force rebuilding of syntax if executable changed
            delete appDirs[filePath]
            delete syntaxWarehouse[dir.appPath]

        # perform completion
        @prepareCompletion request, syntaxWarehouse[dir.appPath]


  prepareCompletion: (request, w) ->
    # tree update
    return unless parser?
    tree = parser.parse request.editor.getBuffer().getText()
    @computeCompletion request, w


  # get the node in the JSON stucture for the current block level
  getSyntaxNode: (configPath, w) ->
    # no parameters at the root
    if configPath.length == 0
      return undefined

    # traverse subblocks
    b = w.json.blocks[configPath[0]]
    for p in configPath[1..]
      b = b?.subblocks?[p] or b?.star
      unless b?
        return undefined
    b


  # get a list of valid subblocks
  getSubblocks: (configPath, w) ->
    # get top level blocks
    if configPath.length == 0
      return Object.keys w.json.blocks

    # traverse subblocks
    b = @getSyntaxNode configPath, w
    ret = Object.keys(b?.subblocks || {})
    if b?.star
      ret.push '*'

    return ret.sort()


  # get a list of parameters for the current block
  # if the type parameter is known add in class specific parameters
  getParameters: (configPath, explicitType, w) ->
    ret = {}
    b = @getSyntaxNode configPath, w

    # handle block level action parameters first
    for n of b?.actions
      Object.assign ret, b.actions[n].parameters

    # if no type is explicitly set check if a default value exists
    currentType = explicitType || ret?.type?.default

    # if the type is known add the specific parameters
    t = b?.subblock_types?[currentType] || b?.types?[currentType]
    Object.assign ret, t?.parameters

    ret


  # get a list of possible completions for the type parameter at the current block level
  getTypes: (configPath, w) ->
    ret = []
    b = @getSyntaxNode configPath, w
    for n of b?.subblock_types
      ret.push {text: n, description: b.subblock_types[n].description}
    for n of b?.types
      ret.push {text: n, description: b.types[n].description}

    ret


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
  computeValueCompletion: (param, editor, isQuoted, hasSpace, w) ->
    singleOK = not hasSpace
    vectorOK = isQuoted or not hasSpace

    hasType = (type) =>
      return (param.cpp_type == type and singleOK) or
             (@isVectorOf(param.cpp_type, type) and vectorOK)

    blockList = []
    buildBlockList = (node, oldPath) ->
      for c in node.children
        if c.type == 'top_block' || c.type == 'block'
          block = c.children[1].text
          block = block[2..] if block[..1] == './'
          newPath = (if oldPath then oldPath + '/' else '') + block
          blockList.push newPath
          buildBlockList c, newPath

    if (param.cpp_type == 'bool' and singleOK) or
       (@isVectorOf(param.cpp_type, 'bool') and vectorOK)
      return [
        {text: 'true'}
        {text: 'false'}
      ]

    if 'options' of param and param.options and
       ((param.basic_type == 'String' and singleOK) or
       (param.basic_type == 'Array:String' and vectorOK))
      if param.options?
        completions = []
        for option in param.options.split ' '
          completions.push {
            text: option
          }
        return completions

    match = param.cpp_type.match /^std::vector<([^>]+)>$/
    if (match and not vectorOK) or (not match and not singleOK)
      return []
    innerType = if match then match[1] else param.cpp_type

    if innerType == 'FileName'
      return @computeFileNameCompletion ['*'], editor

    if innerType == 'MeshFileName'
      return @computeFileNameCompletion ['*.e'], editor

    # automatically generated matches from registerSyntaxType
    if innerType of w.json.global.associated_types
      buildBlockList tree.rootNode
      completions = []
      matches = new Set(w.json.global.associated_types[innerType])
      matches.forEach (match) ->
        if match[-2..] == '/*'
          key = match[..-2]
          for block in blockList
            if block[..key.length-1] == key
              completions.push {text: block[key.length..]}

      if innerType == 'OutputName'
        common_outputs = ['exodus', 'csv', 'console', 'gmv', 'gnuplot', 'json', 'nemesis', 'tecplot', 'vtk', 'xda', 'xdr', 'xmloutput']
        completions.push {text: output, iconHTML: suggestionIcon.output} for output in common_outputs

      return completions

    return []


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
      # get a partial path
      partialPath = line.match(insideBlockTag)[1].replace(/^\.\//, '').split('/')
      partialPath.pop()

      # get the postfix (to determine if we need to append a ] or not)
      postLine = editor.getTextInRange([bufferPosition, [bufferPosition.row, bufferPosition.column+1]])
      blockPostfix = if postLine.length > 0 and postLine[0] == ']' then '' else  ']'

      # handle relative paths
      blockPrefix = if configPath.length > 0 then '[./' else '['

      # add block close tag to suggestions
      if configPath.length > 0 && partialPath.length == 0
        completions.push {
          text: '[../' + blockPostfix
          displayText: '..'
        }

      configPath = configPath.concat(partialPath)
      for completion in @getSubblocks configPath, w
        # add to suggestions if it is a new suggestion
        if completion == '*'
          if !addedWildcard
            completions.push {
              displayText: '*'
              snippet: blockPrefix + '${1:name}' + blockPostfix
            }
            addedWildcard = true
        else if completion != ''
          if (completions.findIndex (c) -> c.displayText == completion) < 0
            completions.push {
              text: blockPrefix + [partialPath..., completion].join('/') + blockPostfix
              displayText: completion
            }

    # suggest parameters
    else if @isParameterCompletion(line)

      # loop over valid parameters
      for name, param of @getParameters configPath, explicitType, w

        # skip deprecated params
        if @hideDeprecatedParams and param.deprecated
          continue

        defaultValue = param.default or ''
        defaultValue = "'#{defaultValue}'" if defaultValue.indexOf(' ') >= 0

        if param.cpp_type == 'bool'
          defaultValue = 'false' if defaultValue == '0'
          defaultValue = 'true'  if defaultValue == '1'

        icon =
          if param.name == 'type'
            suggestionIcon['type']
          else if param.required
            suggestionIcon['required']
          else
            if param.default?
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
      paramName = match[1]
      isQuoted = match[2][0] == "'"
      hasSpace = !!match[3]
      param = (@getParameters configPath, explicitType, w)[paramName]
      unless param?
        return []

      # this takes care of 'broken' type parameters like Executioner/Qudadrature/type
      if paramName == 'type' and param.cpp_type == 'std::string'
        completions = @getTypes configPath, w
      else
        completions = @computeValueCompletion param, editor, isQuoted, hasSpace, w

    # set the custom prefix
    for completion in completions
      completion.replacementPrefix = prefix

    completions


  onDidInsertSuggestion: ({editor, suggestion}) ->
    setTimeout(@triggerAutocomplete.bind(this, editor), 1) if suggestion.type is 'property'


  triggerAutocomplete: (editor) ->
    atom.commands.dispatch(atom.views.getView(editor), 'autocomplete-plus:activate', {activatedManually: false})


  # check if there is an square bracket pair around the cursor
  isOpenBracketPair: (line) ->
    return insideBlockTag.test line


  # check if the current line is a type parameter
  isParameterCompletion: (line) ->
    parameterCompletion.test line


  # determine the active input file path at the current position
  getCurrentConfigPath: (editor, position) ->

    recurseCurrentConfigPath = (node, sourcePath = []) ->
      for c in node.children
        if c.type != 'top_block' && c.type != 'block' && c.type != 'ERROR'
          continue

        # check if we are inside a block or top_block
        cs = c.startPosition
        ce = c.endPosition

        # outside row range
        if position.row < cs.row || position.row > ce.row
          continue

        # in starting row but before starting column
        if position.row == cs.row && position.column < cs.column
          continue

        # in ending row but after ending column
        if position.row == ce.row && position.column > ce.column
          continue

        # if the block does not contain a valid path subnode we give up
        if c.children.length < 2 || c.children[1].type != 'block_path'
          return [c.parent, sourcePath]

        # first block_path node
        if c.type != 'ERROR'
          if c.children[1].startPosition.row >= position.row
            continue
          sourcePath = sourcePath.concat(c.children[1].text.replace(/^\.\//, '').split('/'))

        # if we are in an ERROR block (unclosed) we should try to pick more path elements
        else
          for c2 in c.children
            if c2.type != 'block_path' || c2.startPosition.row >= position.row
              continue
            sourcePath = sourcePath.concat(c2.text.replace(/^\.\//, '').split('/'))

        return recurseCurrentConfigPath c, sourcePath

      return [node, sourcePath]


    [node, sourcePath] = recurseCurrentConfigPath tree.rootNode
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

    # is this a WSL (Windows Subsystem for Linux) path?
    isWSL = filePath[..6].toLowerCase() == '\\\\wsl$\\'

    searchPath = filePath
    matches = []
    loop
      # list all files
      for file in fs.readdirSync(searchPath)
        match = mooseApp.exec(file)
        if match
          fileWithPath = path.join searchPath, file

          # on non-WSL systems we make sure the matched path is executable
          continue if not isWSL and not fs.isExecutableSync fileWithPath

          stats = fs.statSync(fileWithPath)

          # ignore directories that match the naming pattern
          continue if not isWSL and stats.isDirectory()

          fileTime = stats.mtime.getTime()

          # convert from Windows to WSL Unix path
          if isWSL
            wslPath = fileWithPath[7..].split('\\')
            fileWithPath = '/' + wslPath[1..].join('/')
            wslDistro = wslPath[0]
          else
            wslDistro = null

          matches.push {
            appPath: searchPath
            appName: match[1]
            appFile: fileWithPath
            appDate: fileTime
            appWSL : wslDistro
          }

      if matches.length > 0
        # return newest application
        matches.sort (a, b) ->
          b.appDate - a.appDate

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
    {appPath, appName, appFile, appDate, appWSL} = app

    # open notification about syntax generation
    workingNotification = atom.notifications.addInfo 'Rebuilding MOOSE syntax data.', {dismissable: true}

    # rebuild the syntax by running moose with --json
    mooseJSON = new Promise (resolve, reject) =>
      jsonData = ''

      # either run moose or use the offlineSyntax file
      if appFile?
        args = ['--json']
        if atom.config.get "autocomplete-moose.allowTestObjects"
          args.push '--allow-test-objects'

        if appWSL
          moose = cp.spawn 'wsl', ['-d', appWSL, appFile].concat args, {stdio:['pipe','pipe','ignore']}
        else
          moose = cp.spawn appFile, args, {stdio:['pipe','pipe','ignore']}

        moose.stdout.on 'data', (data) ->
          jsonData += data

        moose.on 'close',  (code, signal) ->
          if code is 0
            resolve jsonData
          else
            reject {text: 'Failed to run MOOSE to obtain syntax data', code: code, signal: signal, output: jsonData, appFile: appFile}
      else
        fs.readFile appPath, 'utf8', (error, content) =>
          reject {text: 'Failed to load offline syntax file', name: @offlineSyntax } if error?
          resolve content

    .then (result) ->
      beginMarker = '**START JSON DATA**\n'
      endMarker = '**END JSON DATA**\n'
      begin = result.indexOf beginMarker
      end= result.lastIndexOf endMarker

      throw 'markers not found' if begin < 0 or end < begin

      JSON.parse result[begin+beginMarker.length..end-1]

    .then (result) ->
      w.json = result
      if cacheFile?
        fs.writeFile cacheFile, JSON.stringify(w.json), ->

      workingNotification.dismiss()
      delete w.promise

      w

    .catch (error) ->
      workingNotification.dismiss()
      console.log error
      atom.notifications.addError error?.text or "Failed to obtain syntax data", dismissable: true

    w.promise = mooseJSON


  # fetch JSON syntax data
  loadSyntax: (app) ->
    {appPath, appName, appFile, appDate} = app

    # prepare entry in the syntax warehouse
    w = syntaxWarehouse[appPath] = {}

    # do not cache offlineSyntax
    if appName
      # we cache syntax data here
      cacheDir = path.join __dirname, '..', 'cache'
      fs.makeTreeSync cacheDir
      cacheFile = path.join cacheDir, "#{appName}.json"

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
            # validate cache version
            throw 'Invalid cache' unless 'blocks' of result
            result

          .then (result) ->
            delete w.promise
            w.json = result

          .catch ->
            # TODO: rebuild syntax if loading the cache fails
            atom.notifications.addWarning 'Failed to load cached syntax (probably a legacy cache file).', dismissable: true
            delete syntaxWarehouse[appPath]
            fs.unlink cacheFile, ->

          w.promise = loadCache
          return w.promise

    @rebuildSyntax app, cacheFile, w
