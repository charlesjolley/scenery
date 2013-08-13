###
This module returns a SceneCompiler that can return the zipped content as a
stream. Pass in device-options to control the build. 

TODO: Add hooks for more sophisticated build chains. Need to figure out 
integration with an IDE first.
###

path = require 'path'
glob = require 'glob'
crypto = require 'crypto'
fs = require 'fs'
async = require 'async'
MemoryStream = require 'memorystream-mcavage'
CoffeeScript = require 'coffee-script'
zipstream = require './zipstream'

ZIP_OPTIONS =
  level: 1

ComputeInputFiles = (sceneRoot, done) ->
  # Finds all input files in the sceneRoot.
  sceneGlob = path.join sceneRoot, '**', '*'
  glob sceneGlob, null, (err, files) =>
    return done(err) if err
    processed = []

    # only return actual files.
    async.forEach files, ((filename, next) ->
      fs.stat filename, (err, stat) ->
        return next(err) if err
        if stat.isFile()
          filename = path.relative sceneRoot, filename
          processed.push filename
        next()
    ), (err) -> done(err, processed)
  null


class SceneCompiler

  sceneRoot: null
  ###
  The absolute path to the scene to build.
  ###

  sceneName: null
  ###
  The relative portion of the path that represents the name of the scene.
  ###

  flags: {}
  ###
  This will be populated with properties for each flag found in the 
  constructor. It's easy to test for a flag. `if @flags.foo then ...`
  ###

  constructor: (sceneRoot, opts={}) ->
    ###
    Pass the path to the scene along with the following options:

      * `name` - this should be the name of the app as references in the URL.
        for example name = 'foo' for /scenes/foo
      * `flags` - array of devices flags that can control the build. If the
        client includes this as a query string on the request, pass it in
        here. example: flags: ['idiom.phone','resolution.hi']
    ###
    #super
    flags = opts.flags or []
    @flags[flag] = yes for flag in flags
    @sceneRoot = sceneRoot
    @sceneName = opts.name
    @

  _extfns: {}

  @registerExtension = (extname, handlers) ->
    ###
    Add handlers for a given file extension. The handlers object must 
    implement two methods:

      * `addOutputAssets(filename, outputFiles)` - this should add relative
        filenames to the outputFiles array for the given input filename. 
      
      * `createBuildStream(inputFilename, outputAssetName)` - return a 
        stream object that will contain the built asset.
    ###
    @::_extfns ||= {}
    if not Object.hasOwnProperty(@::, '_extfns')
      @::_extfns = Object.create(@::_extfns)
    @::_extfns[extname] = handlers
    @

  computeOutputAssets: (done) ->
    ###
    Returns array of assetNames that will be built out of this compiler.

    ## Params
      * `done` - callback with format `done(error, arrayOfFilenames)`
    ###
    ComputeInputFiles @sceneRoot, (err, inputFiles) =>
      return done(err) if err
      outputFiles = []
      for filename in inputFiles

        # allow language-specific handlers modify the set. Currently this
        # is only used by .coffee handling.
        extname = path.extname filename
        if @_extfns[extname]
          @_extfns[extname].addOutputAssets.call @, filename, outputFiles
        else
          outputFiles.push filename
      done err, outputFiles
    null

  computeContentHash: (done) ->
    ###
    Compute a unique content hash based on the input content. This is how we
    generate a unique URL for the asset. 

    ## Params
      * `done` - callback with format `done(err, hexDigest:string)`
    ###
    ComputeInputFiles @sceneRoot, (err, files) =>
      return done(err) if err
      files = files.sort()

      HashOneFile = (relativePath, next) =>
        # Generates a hash value for a single file.
        absolutePath = path.join @sceneRoot, relativePath
        fs.stat absolutePath, (err, stat) =>
          return next(err, '') if (err or !stat.isFile())
          hash = crypto.createHash 'md5'
          hash.update new Buffer(relativePath, 'utf8')
          stream = fs.createReadStream absolutePath
          if not hash.write # pre-streaming crypto API in node < v0.9
            stream.on 'data', (data) -> hash.update(data)
            stream.on 'end', -> next(null, hash.digest('hex'))
          else
            stream.pipe(hash, end: no)
            stream.on 'end', -> next(null, hash.digest('hex'))

      # Hash each file - then generate a summary hash.
      # An optimized version could save the hashes for each file and only
      # recalce if the mtime has changed.
      hash = crypto.createHash 'md5'
      async.map files, HashOneFile, (err, hashes) =>
        return done(err) if err
        #console.log "HASHES", @appRoot, files, hashes

        hash = crypto.createHash 'md5'
        hashes.forEach (currentHash) -> hash.update currentHash
        done null, hash.digest('hex')
    null

  createBuildStream: (assetName) ->
    ###
    Returns a ReadStream for a single asset.

    ## Params
      * `assetName` - one of the assetNames returned by `computeOutputAssets`
    ###
    absolutePath = path.join @sceneRoot, assetName
    return fs.createReadStream(absolutePath) if fs.existsSync(absolutePath)

    basePath = absolutePath.slice 0, 0-path.extname(absolutePath).length
    for extname in Object.keys(@_extfns)
      inputFilename = [basePath, extname].join ''
      if fs.existsSync inputFilename
        fn = @_extfns[extname].createBuildStream
        return fn.call @, inputFilename, assetName
    null # not found

  createZipStream: ->
    ###
    Returns a ReadStream that will contain the zip archive. You should call
    `finalize()` on the returned stream to actually complete the zip action.

    Pass a callback to finalize() with the format `done(err, bytesZipped)`

    If you do not read from the returned stream, you can also call toBuffer()
    on it after the finalize callback is invoked to retrieve the contents
    of the zip as a buffer. This is useful for caching.
    ###
    zip = zipstream.createZip ZIP_OPTIONS
    mem = new MemoryStream([])
    mem.pause()
    zip.pipe mem
    AddAsset = (assetName, next) =>
      source = @createBuildStream(assetName)
      zip.addFile source, { name: assetName }, next

    mem.finalize = (done) =>
      @computeOutputAssets (err, assetNames) =>
        return done(err) if err
        async.forEachSeries assetNames, AddAsset, (err) =>
          return done(err) if err
          zip.finalize (bytesZipped) => 
            done(null, bytesZipped)
    mem # return stream instance immediately

####
# CUSTOM EXT HANDLERS
####

GENERATE_SOURCEMAP = no 
# causes a crash on WebKit remote inspector. :(  
# TODO: make this respond to a build flag sent by the Mac version once we 
# can get the version of WebKit inspector in there that supports sourcemaps.

SceneCompiler.registerExtension '.coffee',
  addOutputAssets: (filename, outputFiles) ->
    extname = '.coffee'
    basename = filename.slice 0, 0-extname.length
    outputFiles.push "#{basename}.js"
    if GENERATE_SOURCEMAP
      outputFiles.push filename 
      outputFiles.push "#{basename}.sourcemap"
  
  # creates a build stream based on the extension
  createBuildStream: (inputFilename, outputAssetName) ->
    extname = path.extname outputAssetName
    input = fs.readFileSync inputFilename, 'utf8'
    try
      compiled = CoffeeScript.compile input, 
        filename:  inputFilename
        sourceMap: yes
    catch e
      message = "Compiler Error: #{e.message} at line #{e.location?.first_line} in #{inputFilename}\n\n"
      throw new Error(message)

    if extname == '.js'
      outputExtname = path.extname outputAssetName
      sourceMapPath = path.basename outputAssetName
      sourceMapPath = sourceMapPath.slice 0, 0-outputExtname.length
      if GENERATE_SOURCEMAP
        source = """
        #{compiled.js}

        //@ sourceMappingURL=#{sourceMapPath}.sourcemap

        """
      else
        source = compiled.js

    else if extname == '.sourcemap'
      sourceMap = JSON.parse compiled.v3SourceMap
      sourceMap.file = path.basename inputFilename
      source = JSON.stringify sourceMap, null, 2
    else
      throw new Error("Invalid extension: #{extname}")

    stream = new MemoryStream [source]
    stream.end()
    stream

exports.SceneCompiler = SceneCompiler
