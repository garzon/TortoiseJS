DEFAULT_UPDATE_DELAY = 1000 / 60
MAX_UPDATE_DELAY     = 1000
FAST_UPDATE_EXP      = 0.5
SLOW_UPDATE_EXP      = 4
MAX_UPDATE_TIME      = 100

DEFAULT_REDRAW_DELAY = 1000 / 30
MAX_REDRAW_DELAY     = 1000
REDRAW_EXP           = 2

class window.SessionLite
  constructor: (@widgetController, @displayError) ->
    @_eventLoopTimeout = -1
    @_lastRedraw = 0
    @_lastUpdate = 0
    @widgetController.ractive.on('editor.recompile',   (event) => @recompile())
    @widgetController.ractive.on('exportnlogo',        (event) => @exportnlogo(event))
    @widgetController.ractive.on('exportHtml',         (event) => @exportHtml(event))
    @widgetController.ractive.on('console.run',        (code)  => @run(code))
    @drawEveryFrame = false

  modelTitle: ->
    @widgetController.ractive.get('modelTitle')

  startLoop: ->
    if procedures.startup? then procedures.startup()
    @widgetController.redraw()
    @widgetController.updateWidgets()
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

    if Updater.hasUpdates()
      # First conditional checks if we're on time with updates. If so, we may as
      # well redraw. This keeps animations smooth for fast models. BCH 11/4/2014
      if i > maxNumUpdates or now() - @_lastRedraw > @redrawDelay() or @drawEveryFrame
        @_lastRedraw = now()
        @widgetController.redraw()

    # Widgets must always be updated, because global variables and plots can be
    # altered without triggering an "update".  That is to say that `Updater`
    # only concerns itself with View updates. --JAB (9/2/15)
    @widgetController.updateWidgets()

  teardown: ->
    @widgetController.teardown()
    cancelAnimationFrame(@_eventLoopTimeout)

  recompile: ->
    # This is a temporary workaround for the fact that models can't be reloaded
    # without clearing the world. BCH 1/9/2015
    Tortoise.startLoading( =>
      world.clearAll()
      @widgetController.redraw()
      code = @widgetController.code()
      codeCompile(code, [], [], @widgetController.widgets, (res) =>
        if res.model.success
          globalEval(res.model.result)
          @widgetController.ractive.set('isStale',          false)
          @widgetController.ractive.set('lastCompiledCode', code)
        else
          @alertCompileError(res.model.result)
        Tortoise.finishLoading()
      )
    )

  getNlogo: ->
    (new BrowserCompiler()).exportNlogo({
      info:         Tortoise.toNetLogoMarkdown(@widgetController.ractive.get('info')),
      code:         @widgetController.ractive.get('code'),
      widgets:      @widgetController.widgets,
      turtleShapes: turtleShapes,
      linkShapes:   linkShapes
    })

  exportnlogo: ->
    exportName = @promptFilename(".nlogo")
    if exportName?
      exportedNLogo = @getNlogo()
      if (exportedNLogo.success)
        exportBlob = new Blob([exportedNLogo.result], {type: "text/plain:charset=utf-8"})
        saveAs(exportBlob, exportName)
      else
        @alertCompileError(exportedNLogo.result)

  promptFilename: (extension) =>
    suggestion = @modelTitle() + extension
    window.prompt('Filename:', suggestion)

  exportHtml: ->
    exportName = @promptFilename(".html")
    if exportName?
      window.req = new XMLHttpRequest()
      req.open('GET', standaloneURL)
      req.onreadystatechange = =>
        if req.readyState == req.DONE
          if req.status is 200
            nlogo = @getNlogo()
            if nlogo.success
              parser = new DOMParser()
              dom = parser.parseFromString(req.responseText, "text/html")
              nlogoScript = dom.querySelector("#nlogo-code")
              nlogoScript.textContent = nlogo.result
              nlogoScript.dataset.filename = exportName.replace(/\.html$/, ".nlogo")
              wrapper = document.createElement("div")
              wrapper.appendChild(dom.documentElement)
              exportBlob = new Blob([wrapper.innerHTML], {type: "text/html:charset=utf-8"})
              saveAs(exportBlob, exportName)
            else
              @alertCompileError(nlogo.result)
          else
            alert("Couldn't get standalone page")
      req.send("")

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
    Tortoise.startLoading()
    codeCompile(@widgetController.code(), [code], [], @widgetController.widgets,
      (res) =>
        success = res.commands[0].success
        result  = res.commands[0].result
        Tortoise.finishLoading()
        if (success)
          try window.handlingErrors(new Function(result))()
          catch ex
            if not (ex instanceof Exception.HaltInterrupt)
              throw ex
        else
          @alertCompileError(result))

  alertCompileError: (result) ->
    alertText = result.map((err) -> err.message).join('\n')
    @displayError(alertText)

# See http://perfectionkills.com/global-eval-what-are-the-options/ for what
# this is doing. This is a holdover till we get the model attaching to an
# object instead of global namespace. - BCH 11/3/2014
globalEval = eval

window.AgentModel = tortoise_require('agentmodel')

window.codeCompile = (code, commands, reporters, widgets, onFulfilled) ->
  compileParams = {
    code:         code,
    widgets:      widgets,
    commands:     commands,
    reporters:    reporters,
    turtleShapes: turtleShapes ? [],
    linkShapes:   linkShapes ? []
  }
  onFulfilled((new BrowserCompiler()).fromModel(compileParams))

window.serverNlogoCompile = (model, commands, reporters, widgets, onFulfilled) ->
  compileParams = {
    model:     model,
    commands:  JSON.stringify(commands),
    reporters: JSON.stringify(reporters)
  }
  compileCallback = (res) ->
    onFulfilled(JSON.parse(res))
  ajax('/compile-nlogo', compileParams, compileCallback)

window.serverCodeCompile = (code, commands, reporters, widgets, onFulfilled) ->
  compileParams = {
    code,
    widgets:      JSON.stringify(widgets),
    commands:     JSON.stringify(commands),
    reporters:    JSON.stringify(reporters),
    turtleShapes: JSON.stringify(turtleShapes ? []),
    linkShapes:   JSON.stringify(linkShapes ? [])
  }
  compileCallback = (res) ->
    onFulfilled(JSON.parse(res))
  ajax('/compile-code', compileParams, compileCallback)

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

# performance.now gives submillisecond timing, which improves the event loop
# for models with submillisecond go procedures. Unfortunately, iOS Safari
# doesn't support it. BCH 10/3/2014
now = performance?.now.bind(performance) ? Date.now.bind(Date)
