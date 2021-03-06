# Please note, that [ ..., ..., function ] syntax is needed
# since AngularJS won't be able to inject variables when minified.
# You can also restrict angularjs injection keywords in
# configuration file and skip this.
teghApp.controller 'main', ($scope, $compile, $filter) ->

  # For debugging purposes
  window.mainScope = $scope

  $scope.active = null
  $scope.user = null
  $scope.password = null

  $scope.changePrinter = (service) -> changePrinter($scope, $compile, service)

  $scope.addCert = ->
    service = $scope.active
    service.cert = $scope.cert
    $scope.changePrinter service

  $scope.login = ->
    console.log "log in"
    service = $scope.active
    $scope.changePrinter service


printer = null
previousPrinter = null


b64toBlob = (b64Data, contentType, sliceSize) ->
  contentType = contentType or ""
  sliceSize = sliceSize or 512
  byteCharacters = atob(b64Data)
  byteArrays = []
  offset = 0

  while offset < byteCharacters.length
    slice = byteCharacters.slice(offset, offset + sliceSize)
    byteNumbers = new Array(slice.length)
    i = 0

    while i < slice.length
      byteNumbers[i] = slice.charCodeAt(i)
      i++
    byteArray = new Uint8Array(byteNumbers)
    byteArrays.push byteArray
    offset += sliceSize
  blob = new Blob(byteArrays,
    type: contentType
  )
  blob

changePrinter = ($scope, $compile, service) ->
  # console.log "changing printers"
  # console.log service
  # console.log printer

  $scope.service = service
  previousPrinter = printer

  onPrinterEvent = (event) -> $scope.$apply ->
    # console.log event
    # console.log "New Enabled: #{event.data.target_temp}" if event.data?.enabled?
    printer.processEvent(event)
    # update the heaters and the extruders
    $scope.heaters = _.pick printer.data, (data, key) -> data.type == "heater"
    if _.size($scope.heaters) == 0
      $scope.heaters = null
    $scope.extruders = _.pick $scope.heaters, (data, key) -> key != "b"
    if _.size($scope.heaters) == 0
      $scope.extruders = null
    # Update the camera
    _initCamera() if printer.data.camera? and !ctx?
    _onCameraChange() if event.target == "camera" or event.type == 'initialized'

  service.processEvent = onPrinterEvent
  printer = new tegh.Client(service)
  Window.printer = printer
  displayingError = false

  printer.on "error", (e) ->
    console.log "error!"
    displayingError = true
    onError(e)

  onError = (e) -> $scope.$apply ->
    $scope.active = service
    $scope.cert = printer.cert
    $scope.error = e?.message || "Unknown Error"
    $previousBackdrop = $(".modal-backdrop")
    if $previousBackdrop.length > 0
      timeout = 300
    else
      timeout = 0
    setTimeout _.partial(displayError, e), timeout

  displayError = (e) ->
    $previousBackdrop = $(".modal-backdrop")
    $previousBackdrop.remove()
    if printer.knownName == false and printer.knownCert == false
      console.log "unknown host!"
      $("#new-host-error-modal").modal("show")
    else if printer.knownName == true and printer.knownCert == false
      console.log "new cert!"
      $("#new-cert-error-modal").modal("show")
    else if printer.unauthorized
      console.log "unauthorized!"
      $("#unauthorized-error-modal").modal("show")
    else
      console.log e
      console.log e.stack if e.stack?
      $("#generic-error-modal").modal("show")

  printer.on "initialized", (data) ->
    $scope.p = printer.data
    $scope.active = service
    previousPrinter?.close()
    console.log "initialized"
    # console.log data
    setTimeout afterInitialized, 0

  afterInitialized = ->
    # Hiding the "available printers" sidebar navigation
    jQuery("nav:visible").offcanvas "hide"

  printer.on "close", (e) ->
    # console.log "closed"
    phase = $scope.$root.$$phase;
    active = $scope.service == printer.service
    nullify = -> if active
      $scope.p = null
      $scope.active = null unless displayingError
    if phase == '$apply' or phase == '$digest'
      nullify()
    else
      $scope.$apply nullify
    console.log "closing"
    onError(message: "Connection Lost") if active and !displayingError
    jQuery("nav:visible").offcanvas("show") if active
    jQuery("body").off "click", ".btn-add-print"

  $scope.defaultExtrudeDistance = 5

  $scope.set = (target, attr, val) ->
    # console.log "set?"
    # console.log arguments
    return if target == null
    # Creating a nested diff object with the right target, attr and value
    (data = {})[target] = {}
    val ?= $scope.p[target][attr]
    return unless val?
    data[target][attr] = val
    console.log "setting #{target}.#{attr} to #{val}"
    console.log data
    printer.send "set", data

  $scope.movement = xy_distance: 10, z_distance: 5

  $scope.move = (data) ->
    for axis, direction of data
      distanceKey = "#{if axis == 'z' then 'z' else 'xy'}_distance"
      data[axis] = direction * $scope.movement[distanceKey]
    console.log data
    printer.send "move", data

  $scope.home = (axes) ->
    printer.send "home", axes

  $scope.extrude = (axis, direction) ->
    console.log printer.data
    console.log arguments
    data = {}
    data[axis] = printer.data[axis].distance || $scope.defaultExtrudeDistance
    data[axis] *= direction
    console.log data
    printer.send "move", data

  $scope.print = () ->
    printer.send "print"

  $scope.retryPrint = () ->
    printer.send "retry_print"

  $scope.rm = (id) ->
    printer.send "rm", id

  addJob = ->
    jQuery(".add-print-input")
    .off("change")
    .val("")
    .click()
    .one "change", onJobSelected

  onJobSelected =  ->
    try
      files = jQuery(".add-print-input")[0].files
      printer.send "add_job", file.path for file in files
    catch e

  jQuery("body").on "click", ".btn-add-print", addJob

  $scope.estop = ->
    printer.send "estop"

  $scope.parts = ->
    parts = _.pick printer.data, (data, key) -> data.type == "part"
    _.sortBy parts, "position"

  $scope.extrudeText = (direction) ->
    if direction == 1 then "Extrude" else "Retract"

  $scope.hasCamera = ->
    printer.data.camera?

  ctx = undefined
  previousUrl = undefined
  _initCamera = ->
    $canvas = $('#camera-canvas')
    # Unsupported
    return unless $canvas[0]?.getContext
    ctx = $canvas[0].getContext('2d')
    _resizeCamera()


  _resizeCamera = ->
    return unless ctx?
    # console.log "Resize"
    # $canvas.css 'width',''
    camera = printer.data.camera
    w = $('#camera-canvas').parent().width()
    ctx.canvas.width = w
    ctx.canvas.height = camera.height / camera.width * w

  $ ->
    gui.Window.get().on "resize", _resizeCamera
    $(".manual_ctrl_nav").on "shown.bs.tab", _resizeCamera

  _onCameraChange = ->
    return unless ctx?
    img = new Image()
    img.onload = ->
      ctx.drawImage(img, 0, 0, ctx.canvas.width, ctx.canvas.height)
      window.URL.revokeObjectURL previousUrl if previousUrl?
      previousUrl = img.src
    # console.log atob printer.data.camera.image
    blob = b64toBlob printer.data.camera.image, "image/jpeg"
    img.src = window.URL.createObjectURL blob
    #"data:image/jpeg;base64,#{printer.data.camera.image}"

