#!/usr/bin/env coffee
# User account creation interface for RocHack members using GitHub oauth

qs = require 'querystring'
child_process = require 'child_process'
fs = require 'fs'
express = require 'express'
net = require './net'
config = require './config'

api_host = 'api.github.com'

# http://coffeescriptcookbook.com/chapters/strings/generating-a-unique-id
unique_id = (length=8) ->
  id = ''
  id += Math.random().toString(36).substr(2) while id.length < length
  id.substr 0, length

app = express()

app.use express.bodyParser()
#app.use express.logger()
app.use express.methodOverride()
app.use express.cookieParser config.cookie_secret
app.use express.cookieSession
  'key': 'signup.connect.sess'
  'proxy': true
app.enable 'trust proxy'

user_stuff = {}

app.set 'view engine', 'html'
app.set 'layout', 'layout'
app.engine 'html', require 'hogan-express'
app.set 'views', __dirname + '/views'

app.get '/', (req, res) ->
  res.render 'index'

app.get '/login', (req, res) ->
  unless req.query.code
    # get oauth code
    res.redirect 'https://github.com/login/oauth/authorize?' + qs.stringify
      client_id: config.client_id
      state: req.session.state = unique_id()
      redirect_uri: 'http://account.rochack.org/login'
      scope: 'user'
  else
    # exchange oauth code for access_token
    headers = 
      'Content-Type': 'application/x-www-form-urlencoded'
    body = qs.stringify
      client_id: config.client_id
      client_secret: config.client_secret
      code: req.query.code
    net.post 'github.com', '/login/oauth/access_token', null, headers, body, (status, data) -> 
      if status >= 400
        console.error 'Status', status, 'getting access token.'
        return

      resp = qs.parse(data)
      if resp.error
        console.error 'Error: ' + resp.error
        if resp.error == 'bad_verification_code'
          res.redirect 'login'
        else
          res.end 'Error': + resp.error
        return
      if resp.token_type != 'bearer'
        console.error 'Strange token: ' + resp
        return

      # proceed
      req.session.access_token = resp.access_token
      res.redirect 'create'

app.get '/create', (req, res) ->
  unless token = req.session.access_token
    res.redirect 'login'
    return

  # got access_token
  query =
    'access_token': token
  #res.send 'looking up user'
  net.get api_host, '/user', query, null, null, (status, data) ->
    user = JSON.parse data
    username = user.login
    res.locals = username: username
    req.session.username = username
    user_stuff[username] =
      user: user

    console.log 'User', username, 'requesting an account'

    # check membership
    #res.send 'checking membership'
    path = '/orgs/RocHack/public_members/' + qs.escape username
    net.get api_host, path, query, null, null, (status, data) ->
      is_member = status == 204
      unless is_member
        # not a rochack member
        console.log 'user', username, 'is not a member'
        res.locals.nonmember = true
        res.render 'create'
        return

      # check for existing account
      #res.send 'checking for existing account'
      passwd = child_process.spawn 'getent', ['passwd', username]
      passwd.on 'exit', (code) ->
        if code == 0
          # account exists
          res.locals.duplicate = true
          console.error "User #{username} already has an account."
          res.render 'create'
        else
          # get keys
          net.get api_host, '/user/keys', query, null, null, (status, data) ->
            if status != 200
              res.locals.key_error = true
            else
              try keys = JSON.parse data
              unless keys[0]?.key
                res.locals.no_keys = true
              else
                res.locals.ok = true
                user_stuff[username].keys =
                  (keys.map (key) -> key.key).join '\n'
            # ask user for confirmation and agreement
            res.render 'create'

app.post '/create', (req, res) ->
  unless req.body.agree_to_aup == 'yes'
    # nonacceptance
    res.redirect 'http://simple.wikipedia.org/wiki/Special:Random'
    return

  # session hack
  username = req.session.username
  res.locals.username = username
  user2 = user_stuff[username]
  unless user2
    res.redirect 'create'
    return
  user = user2.user

  # check keys
  #keys_str = req.session.keys_str
  keys_str = user2.keys
  unless keys_str
    res.end 'No keys. <a href="create">Try again</a>'
    return

  # create account
  #user = try JSON.parse req.session.user
  unless user2
    console.error 'No user object in session'
    res.redirect 'create'
    return

  #username = user.username
  home = '/home/' + username
  args = [
    '-m', '-N'
    '-s', '/bin/bash'
    '-g', 'rochack'
    '-G', 'users'
    '-d', home
    '-c', user.name
    username
  ]

  #res.send 'Creating account...'
  useradd = child_process.spawn 'useradd', args
  useradd.stderr.on 'data', (data) ->
    console.error data.toString()
  useradd.on 'exit', (code) ->
    if code != 0
      #console.error 'useradd failed.'
      res.locals.fail = true
      res.render 'create2'
      return
    console.log 'Added user ' + username

    # account created.

    id = child_process.spawn 'id', ['-u', username]
    id.stdout.on 'data', (data) ->
      uid = Number data.toString()
      gid = 1000

      # import ssh keys
      #res.send 'Importing your public keys...'
      # todo: setuid/gid this script
      child_process.exec 'chmod 755 . && ' +
        'mkdir .ssh && ' +
        'chmod 700 .ssh && ' +
        'touch .ssh/authorized_keys && ' +
        'chmod 600 .ssh/authorized_keys && ' +
        "chown -R #{uid}:#{gid} .",
        cwd: home, (err, stdout, stderr) ->
          if stderr
            console.error stderr
          if err
            console.error 'exec error:', err
            res.locals.key_fail = true
            res.render 'create2'
            return

          # write keys
          fs.writeFile home + '/.ssh/authorized_keys', keys_str, (err) ->
            if err
              console.error err
              res.locals.key_fail = true
              res.render 'create2'
              return
            res.locals.key_success = true

            console.log 'Wrote authorized_keys for', username

            # set up email forwarding
            #res.send "Adding email forward for #{user.email}..."
            fs.writeFile home + '/.forward', user.email, (err) ->
              if err
                console.error err
                res.locals.forward_fail = true
              else
                console.log 'Wrote .forward:', user.email
                res.locals.forward_success = true

              # notify admin
              #'', config.signup_notify_email

              res.render 'create2'

app.listen 9001, '127.0.0.1'
console.log 'Listening on port 9001'
