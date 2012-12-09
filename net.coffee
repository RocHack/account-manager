# Network shim.
# Original by tcr: https://gist.github.com/1306996

https = require 'https'
qs = require 'querystring'

module.exports =
  get: (host, path, query, headers, data, cb) ->
    headers['Content-Length'] = data.length if headers
    options =
      method: if data then 'POST' else 'GET'
      host: host
      headers: headers
      path: if query then path + '?' + qs.stringify query else path
    req = https.request options, (res) ->
      statusCode = Number(res.statusCode)
      data = ''
      res.on 'data', (d) -> data += d
      res.on 'end', ->
        cb statusCode, data
    req.end()

  post: (host, path, query, headers, data, cb) ->
    headers['Content-Length'] = data.length if headers
    options =
      method: if data then 'POST' else 'GET'
      host: host
      headers: headers
      path: if query then path + '?' + qs.stringify query else path
    req = https.request options, (res) ->
      statusCode = Number(res.statusCode)
      data = ''
      res.on 'data', (d) -> data += d
      res.on 'end', ->
        cb statusCode, data
    req.end data

