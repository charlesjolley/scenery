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

class AssetPath
  constructor: (path) -> @path = path
    
class ScenePackage
  constructor: (sceneName) ->
    @name = sceneName
    @assets = {}

  _extfns: {}
  
  @registerExtension = (extname, handlerFn) ->
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
    @::_extfns[extname] = handlerFn
    @
    
  load: (sceneRoot, done) ->
    ###
    Finds all input files in the sceneRoot and adds them to the package
    with an alias to the path. Compilable-files [such as CoffeeScript] will
    be compiled and included as well. Calling this more than once won't do
    anything.
    ###
    ComputeInputFiles sceneRoot, (err, inputFiles) =>
      return done(err) if err
      for assetName in inputFiles
      
        # allow language-specific handlers modify the set. Currently this
        # is only used by .coffee handling.
        extname = path.extname assetName
        assetPath = path.resolve(sceneRoot, assetName)
        if @_extfns[extname]
          err = @_extfns[extname].call @, assetName, assetPath
          return done(err) if err
        else
          @set assetName, new AssetPath(assetPath)
      done()
  
  # sets an asset path to the value, which can be an instance of AssetPath,
  # a string, Steam, or Buffer [which will be sent]. Replaces any previously
  # set value for the same assetPath
  set: (assetPath, value) -> @assets[assetPath] = value

  createBuildStream: (assetName) ->
    ###
    Returns a ReadStream for a single asset.
  
    ## Params
      * `assetName` - one of the assetNames returned by `computeOutputAssets`
    ###
    assetValue = @assets[assetName]
    if assetValue instanceof AssetPath
      absolutePath = assetValue.path
      return fs.createReadStream(absolutePath) if fs.existsSync(absolutePath)
    else if ('string' == typeof assetValue) or assetValue instanceof Buffer 
      stream = new MemoryStream [assetValue]
      stream.end()
      return stream
    null
    
  computeContentHash: (done) ->
    HashOneFileOrString = (assetName, next) =>
      assetValue = @assets[assetName]
      if assetValue instanceof AssetPath
        # Generates a hash value for an AssetPath
        absolutePath = assetValue.path
        fs.stat absolutePath, (err, stat) =>
          return next(err, '') if (err or !stat.isFile())
          hash = crypto.createHash 'md5'
          hash.update new Buffer(assetName, 'utf8')
          stream = fs.createReadStream absolutePath
          if not hash.write # pre-streaming crypto API in node < v0.9
            stream.on 'data', (data) -> hash.update(data)
            stream.on 'end', -> next(null, hash.digest('hex'))
          else
            stream.pipe(hash, end: no)
            stream.on 'end', -> next(null, hash.digest('hex'))
      else if 'string' == typeof assetValue
        hash = crypto.createHash 'md5'
        hash.update new Buffer(assetName, 'utf8')
        hash.update new Buffer(assetValue, 'utf8')
        next(null, hash.digest('hex'))
        
      else
        next new Error("Unknown asset value: #{assetName} = #{assetValue}")
    
    
    # Hash each file - then generate a summary hash.
    # An optimized version could save the hashes for each file and only
    # recalce if the mtime has changed.
    files = Object.keys(@assets).sort()
    hash = crypto.createHash 'md5'
    async.map files, HashOneFileOrString, (err, hashes) =>
      return done(err) if err
      #console.log "HASHES", @appRoot, files, hashes
  
      hash = crypto.createHash 'md5'
      hashes.forEach (currentHash) -> hash.update currentHash
      done null, hash.digest('hex')


####
# CUSTOM EXT HANDLERS
####

GENERATE_SOURCEMAP = no 
# causes a crash on WebKit remote inspector. :(  
# TODO: make this respond to a build flag sent by the Mac version once we 
# can get the version of WebKit inspector in there that supports sourcemaps.

ScenePackage.registerExtension '.coffee', (assetName, assetPath) ->
  extname = '.coffee'
  basename = assetName.slice 0, 0-extname.length    
  jsAssetName = "#{basename}.js"
  sourcemapAssetName = "#{basename}.sourcemap"

  input = fs.readFileSync assetPath, 'utf8'
  try
    compiled = CoffeeScript.compile input, 
      filename:  assetPath
      sourceMap: yes
  catch e
    message = "Compiler Error: #{e.message} at line #{e.location?.first_line} in #{assetPath}\n\n"
    console.error message
    return new Error(message)

  # generate JS
  source = if GENERATE_SOURCEMAP
    """
    #{compiled.js}
  
    //@ sourceMappingURL=#{path.basename sourcemapAssetName}
  
    """
  else compiled.js
  @set jsAssetName, source

  #generate sourcemap
  if GENERATE_SOURCEMAP
    sourceMap = JSON.parse compiled.v3SourceMap
    sourceMap.file = path.basename assetName
    source = JSON.stringify sourceMap, null, 2
    @set sourcemapAssetName, source
  
  null

ZIP_OPTIONS =
  level: 1



EXPIRATION_LENGTH = 1 * 365 * 24 * 60 * 60  # 1 years

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

  constructor: (sceneRootOrPackage, opts={}) ->
    ###
    Pass the path to the scene along with the following options:

      * `name` - this should be the name of the app as references in the URL.
        for example name = 'foo' for /scenes/foo
      * `flags` - array of devices flags that can control the build. If the
        client includes this as a query string on the request, pass it in
        here. example: flags: ['idiom.phone','resolution.hi']
    
    If you pass your own scenePackage you are responsible for loading it 
    first.
    ###
    #super
    flags = opts.flags or []
    @flags[flag] = yes for flag in flags
    if sceneRootOrPackage instanceof ScenePackage
      @scenePackage = sceneRootOrPackage
      @sceneLoaded = yes
    else
      @sceneRoot = sceneRootOrPackage
      @scenePackage = new ScenePackage(path.basename @sceneRoot)
      @sceneLoaded = no

    @sceneName = opts.name
    @


  computeOutputAssets: (done) ->
    ###
    Returns array of assetNames that will be built out of this compiler.

    ## Params
      * `done` - callback with format `done(error, arrayOfFilenames)`
    ###
    return done(null, Object.keys(@scenePackage.assets)) if @sceneLoaded
    @sceneLoaded = yes
    @scenePackage.load @sceneRoot, (err) =>
      return done(err, Object.keys(@scenePackage.assets))      
    null

  computeContentHash: (done) ->
    ###
    Compute a unique content hash based on the input content. This is how we
    generate a unique URL for the asset. 

    ## Params
      * `done` - callback with format `done(err, hexDigest:string)`
    ###
    @computeOutputAssets (err, assetNames) =>
      return done(err) if err
      @scenePackage.computeContentHash done
    null

  createBuildStream: (assetName) ->
    ###
    Returns a ReadStream for a single asset.

    ## Params
      * `assetName` - one of the assetNames returned by `computeOutputAssets`
    ###
    return @scenePackage.screanBuildStream(assetName)

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
      source = @scenePackage.createBuildStream(assetName)
      zip.addFile source, { name: assetName }, next

    mem.finalize = (done) =>
      @computeOutputAssets (err, assetNames) =>
        return done(err) if err
        async.forEachSeries assetNames, AddAsset, (err) =>
          return done(err) if err
          zip.finalize (bytesZipped) => 
            done(null, bytesZipped)
    mem # return stream instance immediately
    
  redirectToStableURL: (baseURL, res, done=->) ->
    ###
    Call from middleware/express handlers to generate the proper URL
    and redirect to said URL.
    ###
    @computeContentHash (err, digest) ->
      return done(err) if err
      stableURL = path.resolve '/', baseURL, 'static', digest
      res.redirect stableURL
      done()
  
  
  sendZippedScene: (inputDigest, res, opts, done) ->
    ###
    Call from middleware/express handlers to send zipped asset. this will
    check the passed digest first and return an error with a code of 404
    if they don't match.
    ###
    # Internal method actually returns the contents of a scene. Expects an
    # already normalized sceneName and absolute sceneRoot path.
    if not done
      if 'function' == typeof opts
        done = opts
        opts = {}
      else
        done = ->
    opts ||= {}
    contentType = opts.contentType or switch path.extname(@sceneRoot or '/')
      when '.scene' then 'application/scene-zip'
      when '.scenelib' then 'application/scenelib-zip'
      else 'zip'
  
    @computeContentHash (err, digest) =>
      if inputDigest && inputDigest != digest
        err = new Error('Not Found')
        err.code = 404
        return done(err)
        
      zip = @createZipStream()
      zip.finalize (err, bytes) =>
        return done(err) if err
        expirationDate = new Date(Date.now() + EXPIRATION_LENGTH*1000)
        res.header 'Cache-Control', "public, max-age=#{EXPIRATION_LENGTH}"
        res.header 'Expires', expirationDate.toUTCString()
        res.header 'Content-Type', contentType
        res.header 'Content-Disposition', "attachment; filename=\"#{@scenePackage.name}.zip\""
        res.header 'Content-Length', bytes
        zip.pipe res
        zip.resume()
        done()
      



exports.SceneCompiler = SceneCompiler
exports.ScenePackage = ScenePackage
exports.AssetPath = AssetPath
