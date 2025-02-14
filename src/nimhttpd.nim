import 
  asyncdispatch,
  asynchttpserver,
  mimetypes, 
  nativesockets,
  os,
  parseopt,
  strutils,
  times, 
  uri,
  algorithm
  
from httpcore import HttpMethod, HttpHeaders, parseHeader

import
  nimhttpdpkg/config

const
  name = pkgTitle
  version = pkgVersion
  style = "style.css".slurp
  description = pkgDescription
  author = pkgAuthor
  addressDefault4 = "127.0.0.1"
  addressDefault6 = "0:0:0:0:0:0:0:1"
  portDefault = 1337
  
let usage = """ $1 v$2 - $3
  (c) 2014-2023 $4

  Usage:
    nimhttpd [-p:port] [directory]

  Arguments:
    directory      The directory to serve (default: current directory).

  Options:
    -t, --title    The title to use in index pages (default: Index)
    -p, --port     The port to listen to (default: $5). If the specified port is
                   unavailable, the number will be incremented until an available port is found.
    -s, --sort     Sort. Can be None or Name. (default: None)
    -a, --address  The IPv4 address to listen to (default: $6).
    -6, --ipv6     The IPv6 address to listen to (default: $7).
    -H  --header   Add a custom header. Multiple headers can be added.
""" % [name, version, description, author, $portDefault, $addressDefault4, $addressDefault6]


type 
  NimHttpResponse* = tuple[
    code: HttpCode,
    content: string,
    headers: HttpHeaders]
  SortType = enum
    sortNone, sortName
  NimHttpSettings* = object
    logging*: bool
    directory*: string
    mimes*: MimeDb
    port*: Port
    title*: string
    address4*: string
    address6*: string
    name*: string
    version*: string
    headers*: HttpHeaders
    sort*: SortType
proc hPage(settings:NimHttpSettings, content, title, subtitle: string): string =
  var footer = """<div id="footer">$1 v$2</div>""" % [settings.name, settings.version]
  result = """
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="$3">
    <title>$1</title>
    <style>$2</style>
  </head>
  <body>
    <h1>$1</h1>
    <h2>$3</h2>
    $4
    $5
  </body>
</html>
  """ % [title, style, subtitle, content, footer]

proc relativePath(path, cwd: string): string =
  var path2 = path
  if cwd == "/":
    return path
  else:
    path2.delete(0..cwd.len-1)
  var relpath = path2.replace("\\", "/")
  if (not relpath.endsWith("/")) and (not path.fileExists):
    relpath = relpath&"/"
  if not relpath.startsWith("/"):
    relpath = "/"&relpath
  return relpath

proc relativeParent(path, cwd: string): string =
  var relparent = path.parentDir.relativePath(cwd)
  if relparent == "":
    return "/"
  else: 
    return relparent

proc sendNotFound(settings: NimHttpSettings, path: string): NimHttpResponse = 
  var content = "<p>The page you requested cannot be found.<p>"
  return (code: Http404, content: hPage(settings, content, $int(Http404), "Not Found"), headers: {"Content-Type": "text/html"}.newHttpHeaders())

proc sendNotImplemented(settings: NimHttpSettings, path: string): NimHttpResponse =
  var content = "<p>This server does not support the functionality required to fulfill the request.</p>"
  return (code: Http501, content: hPage(settings, content, $int(Http501), "Not Implemented"), headers: {"Content-Type": "text/html"}.newHttpHeaders())

proc sendStaticFile(settings: NimHttpSettings, path: string): NimHttpResponse =
  var
    mimes = settings.mimes
    ext = path.splitFile.ext
  if ext == "": ext = ".txt" else: ext = ext[1 .. ^1]
  let mimetype = mimes.getMimetype(ext.toLowerAscii)
  var file = path.readFile
  return (code: Http200, content: file, headers: {"Content-Type": mimetype}.newHttpHeaders)

iterator walk(path: string, sort: SortType): string =
  if sort == sortNone:
    for i in walkDir(path):
      yield i.path
  else:
    var f: seq[string]
    for i in walkDir(path):
      f.add(i.path)
    f.sort()
    for i in f:
      yield i

proc sendDirContents(settings: NimHttpSettings, dir: string): NimHttpResponse = 
  var
    res: NimHttpResponse
    cwd = settings.directory.absolutePath
    files = newSeq[string](0)
    path = dir.absolutePath
  if not path.startsWith(cwd):
    path = cwd
  if path != cwd and path != cwd&"/" and path != cwd&"\\":
    files.add """<li class="i-back entypo"><a href="$1">..</a></li>""" % [path.relativeParent(cwd)]
  var title = settings.title
  let subtitle = path.relativePath(cwd)
  
  for i in walk(path, settings.sort):
    let name = i.extractFilename
    let relpath = i.relativePath(cwd)
    if name == "index.html" or name == "index.htm":
      return sendStaticFile(settings, i)
    if i.dirExists:
      files.add """<li class="i-folder entypo"><a href="$1">$2</a></li>""" % [relpath, name]
    else:
      files.add """<li class="i-file entypo"><a href="$1">$2</a></li>""" % [relpath, name]
  let ul = """
<ul>
  $1
</ul>
""" % [files.join("\n")]
  res = (code: Http200, content: hPage(settings, ul, title, subtitle), headers: {"Content-Type": "text/html"}.newHttpHeaders())
  return res

proc printReqInfo(settings: NimHttpSettings, req: Request) =
  if not settings.logging:
    return
  echo getTime().local, " - ", req.hostname, " ", req.reqMethod, " ", req.url.path

proc handleCtrlC() {.noconv.} =
  echo "\nExiting..."
  quit()

setControlCHook(handleCtrlC)

proc genMsg(settings: NimHttpSettings): string =
  let t = now()
  let pid = getCurrentProcessId()
  result = """$1 v$2
Address (IPv4): http://$3:$5
Address (IPv6): http://$4:$5
Directory:      $6
Current Time:   $7 
PID:            $8""" % [settings.name, settings.version, settings.address4, settings.address6, $settings.port, settings.directory.quoteShell, $t, $pid]

proc serve*(settings: NimHttpSettings) =
  var server = newAsyncHttpServer()
  proc handleHttpRequest(req: Request): Future[void] {.async.} =
    printReqInfo(settings, req)
    let path = settings.directory/req.url.path.replace("%20", " ").decodeUrl()
    var res: NimHttpResponse 
    res.headers = settings.headers
    if req.reqMethod != HttpGet:
      res = sendNotImplemented(settings, path)
    elif path.dirExists:
      res = sendDirContents(settings, path)
    elif path.fileExists:
      res = sendStaticFile(settings, path)
    else:
      res = sendNotFound(settings, path)
    for key, value in settings.headers:
      res.headers[key] = value
    await req.respond(res.code, res.content, res.headers)
  echo genMsg(settings)
  asyncCheck server.serve(settings.port, handleHttpRequest, settings.address4, -1, AF_INET)
  asyncCheck server.serve(settings.port, handleHttpRequest, settings.address6, -1, AF_INET6)

when isMainModule:

  var port = portDefault
  var address4 = addressDefault4
  var address6 = addressDefault6
  var logging = false
  var www = getCurrentDir()
  var title = "Index"
  var headers = newHttpHeaders()
  var sort = sortNone

  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "log", "l":
        logging = true
      of "help", "h":
        echo usage
        quit(0)
      of "version", "v":
        echo version
        quit(0)
      of "address", "a":
        address4 = val
      of "ipv6", "6":
        address6 = val
      of "title", "t":
        title = val
      of "port", "p":
        try:
          port = val.parseInt
        except:
          if val == "":
            echo "Port not set."
            quit(2)
          else:
            echo "Error: Invalid port: '", val, "'"
            echo "Running on default port instead."
      of "header", "H":
        let (key, values) = parseHeader(val)
        headers[key] = values
      of "sort", "s":
        case val:
          of "name":
            sort = sortName
          else:
            echo "Sort need be 'name' if set"  # TODO: more sorts
            quit(3)
      else:
        discard
    of cmdArgument:
      var dir: string
      if key.isAbsolute:
        dir = key
      else:
        dir = www/key
      if dir.dirExists:
        www = expandFilename dir
      else:
        echo "Error: Directory '"&dir&"' does not exist."
        quit(1)
    else: 
      discard
  
  var addrInfo4 = getAddrInfo(address4, Port(port), AF_INET)
  var addrInfo6 = getAddrInfo(address6, Port(port), AF_INET6)
  if (addrInfo4 == nil) and (addrInfo6 == nil):
    echo "Error: Could not resolve given IPv4 or IPv6 addresses."
    quit(1)
  freeAddrInfo(addrInfo4)
  freeAddrInfo(addrInfo6)
  
  var settings: NimHttpSettings
  settings.directory = www
  settings.logging = logging
  settings.mimes = newMimeTypes()
  settings.mimes.register("htm", "text/html")
  settings.address4 = address4
  settings.address6 = address6
  settings.name = name
  settings.title = title
  settings.version = version
  settings.port = Port(port)
  settings.headers = headers
  settings.sort = sort

  serve(settings)
  runForever()
