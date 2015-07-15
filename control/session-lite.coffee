DEFAULT_UPDATE_DELAY = 1000 / 60
MAX_UPDATE_DELAY     = 1000
FAST_UPDATE_EXP      = 0.5
SLOW_UPDATE_EXP      = 4
MAX_UPDATE_TIME      = 100

DEFAULT_REDRAW_DELAY = 1000 / 30
MAX_REDRAW_DELAY     = 1000
REDRAW_EXP           = 2

class window.SessionLite
  constructor: (@widgetController) ->
    @_eventLoopTimeout = -1
    @_lastRedraw = 0
    @_lastUpdate = 0
    @widgetController.ractive.on('editor.recompile',   (event) => @recompile())
    @widgetController.ractive.on('exportnlogo',        (event) => @exportnlogo(event))
    @widgetController.ractive.on('console.run',        (code)  => @run(code))
    @drawEveryFrame = false

  startLoop: ->
    @widgetController.updateWidgets()
    if procedures.startup? then Call(procedures.startup)
    requestAnimationFrame(@eventLoop)

  updateDelay: ->
    speed = @widgetController.speed()
    if speed > 0
      speedFactor = Math.pow(Math.abs(speed), FAST_UPDATE_EXP)
      DEFAULT_UPDATE_DELAY * (1 - speedFactor)
    else
      speedFactor = Math.pow(Math.abs(speed), SLOW_UPDATE_EXP)
      MAX_UPDATE_DELAY * speedFactor + DEFAULT_UPDATE_DELAY * (1 - speedFactor)

  redrawDelay: ->
    speed       = @widgetController.speed()
    if speed > 0
      speedFactor = Math.pow(Math.abs(@widgetController.speed()), REDRAW_EXP)
      MAX_REDRAW_DELAY * speedFactor + DEFAULT_REDRAW_DELAY * (1 - speedFactor)
    else
      DEFAULT_REDRAW_DELAY

  eventLoop: (timestamp) =>
    @_eventLoopTimeout = requestAnimationFrame(@eventLoop)
    updatesDeadline = Math.min(@_lastRedraw + @redrawDelay(), now() + MAX_UPDATE_TIME)
    maxNumUpdates   = if @drawEveryFrame then 1 else (now() - @_lastUpdate) / @updateDelay()

    for i in [1..maxNumUpdates] by 1 # maxNumUpdates can be 0. Need to guarantee i is ascending.
      @_lastUpdate = now()
      @widgetController.runForevers()
      if now() >= updatesDeadline
        break

    # First conditional checks if we're on time with updates. If so, we may as
    # well redraw. This keeps animations smooth for fast models. BCH 11/4/2014
    if i > maxNumUpdates or now() - @_lastRedraw > @redrawDelay() or @drawEveryFrame
      @_lastRedraw = now()
      # TODO: Once Updater.anyUpdates() exist, switch to only redrawing when there are updates
      @widgetController.redraw()
    @widgetController.updateWidgets()

  teardown: ->
    @widgetController.teardown()
    cancelAnimationFrame(@_eventLoopTimeout)

  recompile: ->
    # This is a temporary workaround for the fact that models can't be reloaded
    # without clearing the world. BCH 1/9/2015
    world.clearAll()
    @widgetController.redraw()
    compile('code', @widgetController.code(), [], [], @widgetController.widgets, (res) ->
      if res.model.success
        globalEval(res.model.result)
      else
        alert(res.model.result.map((err) -> err.message).join('\n')))


  exportnlogo: ->
    filename = window.prompt('Filename:', @widgetController.ractive.get('filename'))
    if filename?
      form = @makeForm('post', '/export-code', {
        filename: filename,
        info:     @widgetController.ractive.get('info'),
        model:    @widgetController.ractive.get('code'),
        widgets:  JSON.stringify(@widgetController.widgets)
      })
      document.body.appendChild(form)
      form.submit()

  makeForm:(method, path, data) ->
    form = document.createElement('form')
    form.setAttribute('method', method)
    form.setAttribute('action', path)
    for name, value of data
      field = document.createElement('input')
      field.setAttribute('type', 'hidden')
      field.setAttribute('name', name)
      field.setAttribute('value', value)
      form.appendChild(field)
    form


  run: (code) ->
    compile('code', @widgetController.code(), [code], [], @widgetController.widgets,
      (res) ->
        success = res.commands[0].success
        result  = res.commands[0].result
        if (success)
          new Function(result)()
        else
          alert(result.map((err) -> err.message).join('\n'))
      ,
      (err) -> alert(err))

window.Tortoise = {
  normalizedFileName: (path) ->
    # We separate on both / and \ because we get URLs and Windows-esque filepaths
    pathComponents = path.split(/\/|\\/)
    decodeURI(pathComponents[pathComponents.length - 1])

  fromNlogo:         (nlogo, container, path, callback) ->
    compile("nlogo", nlogo, [], [], [], makeCompileCallback(container, callback, @normalizedFileName(path)))
  fromURL:           (url,   container, callback) ->
    compile("url",   url,   [], [], [], makeCompileCallback(container, callback, @normalizedFileName(url)))

  fromCompiledModel: (container,
                      widgetString,
                      code,
                      info,
                      compiledSource = "",
                      readOnly = false,
                      filename = "export.nlogo") ->
    widgets = globalEval(widgetString)
    widgetController = bindWidgets(container, widgets, code, info, readOnly, filename)
    window.modelConfig ?= {}
    modelConfig.plotOps = widgetController.plotOps
    modelConfig.mouse = widgetController.mouse
    modelConfig.print = { write: widgetController.write }
    modelConfig.output = widgetController.output
    globalEval(compiledSource)
    new SessionLite(widgetController)
}

window.AgentModel = tortoise_require('agentmodel')

makeCompileCallback = (container, callback, filename) ->
  (res) ->
    if res.model.success
      callback(Tortoise.fromCompiledModel(container, res.widgets, res.code,
        res.info, res.model.result, false, filename))
    else
      container.innerHTML = res.model.result.map((err) -> err.message).join('<br/>')

window.compile = (source, model, commands, reporters, widgets,
                  onFulfilled, onRejected = (s) -> throw s) ->
  compileParams = {
    model: model,
    widgets: JSON.stringify(widgets),
    commands: JSON.stringify(commands),
    reporters: JSON.stringify(reporters),
    turtleShapes: JSON.stringify(turtleShapes ? []),
    linkShapes: JSON.stringify(linkShapes ? [])
  }
  compileCallback = (res) ->
    onFulfilled(JSON.parse(res))
  ajax('/compile-'+source, compileParams, compileCallback)

window.ajax = (url, params, callback) ->
  paramPairs = for key, value of params
    encodeURIComponent(key) + '=' + encodeURIComponent(value)
  req = new XMLHttpRequest()
  req.open('POST', url)
  req.onreadystatechange = ->
    if req.readyState == req.DONE
      callback(req.responseText)
  req.setRequestHeader('Content-type', 'application/x-www-form-urlencoded')
  req.send(paramPairs.join('&'))

# See http://perfectionkills.com/global-eval-what-are-the-options/ for what
# this is doing. This is a holdover till we get the model attaching to an
# object instead of global namespace. - BCH 11/3/2014
globalEval = eval

# performance.now gives submillisecond timing, which improves the event loop
# for models with submillisecond go procedures. Unfortunately, iOS Safari
# doesn't support it. BCH 10/3/2014
now = performance?.now.bind(performance) ? Date.now.bind(Date)
