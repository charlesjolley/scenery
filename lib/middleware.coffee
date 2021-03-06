###
Exposes connect middleware you can use to host scenes. To use:

    // setup
    var scenery = require('scenery/middleware');
    var path = require('path');

This mounts a single scene at /scenes/app_name. Note that you should
never include the '.scene' or '.scenelib' extension in the mounted name. 
Some proxies on the internet will improperly cache URLs with extensions.

    var PATH_TO_SCENE = path.join(__dirname, 'scenes/app_name.scene');
    app.use('/scenes', scenery.scene('scene_name', PATH_TO_SCENE));

This mounts an entire directory. It will serve any .scene or .scenelib dirs:

    var PATH_TO_SCENES = path.join(__dirname, 'scenes');
    app.use('/scenes', scenery.mount(PATH_TO_SCENES, { watch: true }));

Passing the `{ watch: true }` option will watch the directory and recompute
any cached assets. You can also set `{ cache: false }` to disable caching.
This is not generally advised.
###

URL  = require 'url'
PATH = require 'path'
FS   = require 'fs'
ASYNC = require 'async'
{SceneCompiler} = require './scene_compiler'

URL_REGEX = /^\/?(.+?)(\/static\/([^\/]+))?\/?$/

ExtractRequest = (req) ->
  # Returns array of options extracted from the request. If request is not 
  # valid (including illegal HTTP method) returns null
  return [no] unless req.method == 'GET' or req.method == 'HEAD'
  urlPathname = PATH.resolve '/', URL.parse(req.url).pathname
  parts = URL_REGEX.exec urlPathname
  sceneName = parts?[1]
  version   = parts?[3] or 'current'
  valid     = !!(sceneName and version)
  [valid, sceneName, version]

HandleScene = (sceneName, version, sceneRoot, opts, req, res, next) ->
  SceneCompilerClass = opts.compiler or SceneCompiler
  scenec = new SceneCompilerClass(sceneRoot, name: sceneName)
  if version == 'current'
    scenec.redirectToStableURL req.originalUrl, res, (err) ->
      res.send(500, String(err)) if err
  else
    scenec.sendZippedScene version, res, (err) ->
      if err
        if err.code == 404 then next()
        else res.send(err.code or 500, String(err))

exports.mount = (scenesRoot, opts={}) ->
  ###
  Returns an express middleware that will servce any scenes founds in the 
  scenesRoot directory. This will respond to two URLs:

    * `/{sceneName}/current` - redirects to a stable URL reflecting
      the current version of the scene.
    * `/{sceneName}/{hashId}` - a stable URL that returns a zip 
      archive of the scene with far-future expires.

  You can configure this handler with several options:

    * `extensions` - array of valid extensions. Default is 
      ['scene','scenelib']. Set to empty string or null to look for 
      directory names.
    * `cache` - [Not Yet Implemented] - stores returned values in a cache to 
      avoid recalculating each time. Set to environment name or false to 
      disable. Default is 'production'.
  ###

  # normalize inputs
  scenesRoot = PATH.resolve scenesRoot

  exts = opts.extensions
  if exts == false or (exts == null and opts.hasOwnProperty('extensions'))
    exts = ['']

  exts ||= ['.scene', '.scenelib']
  exts = [exts] if 'string' == typeof exts
  opts.extensions = exts.map (ext) ->
    if ext.length==0 or ext.match /^\./ then ext else ".#{ext}"
  opts.cache ||= 'production'

  (req, res, next) ->
    [valid, sceneName, version] = ExtractRequest req
    return next() if not valid
    candidates = opts.extensions.map (ext) ->
      PATH.resolve scenesRoot, "#{sceneName}#{ext}"
    ASYNC.detect candidates, FS.exists, (sceneRoot) ->
      return next() if not sceneRoot # becomes 404
      HandleScene sceneName, version, sceneRoot, opts, req, res, next

exports.scene = (sceneName, sceneRoot, opts={}) ->
  ###
  Returns an express middleware for the specified scene. This will respond to
  two URLs:

    * `{sceneName}/current` - returns a redirect to a stable URL reflecting 
      the current version of the scene. 
    * `{sceneName}/{hashId}` - a stable URL reflecting a particular version.
      If the hashId matches the current version then it will return the zip
      archive contents along with far-future expires cache headers.
  ###
  sceneName = PATH.resolve('/', sceneName).slice(1) # '/taxi/' -> 'taxi'
  sceneRoot = PATH.resolve(sceneRoot)
  opts.cache ||= 'production'
  if not FS.existsSync(sceneRoot) then throw new Error """
    cannot mount scene '#{sceneName}', #{sceneRoot} does not exist
    """
  (req, res, next) ->
    [valid, foundSceneName, version] = ExtractRequest req
    return next() if not valid or foundSceneName != sceneName
    HandleScene sceneName, version, sceneRoot, opts, req, res, next
