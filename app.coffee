#!/usr/bin/env coffee
#vi: ts=2 sts=2 sw=2 et
# User account creation interface for RocHack members using GitHub oauth

qs = require 'querystring'
child_process = require 'child_process'
fs = require 'fs'
express = require 'express'
net = require './net'
config = require './config'
hogan_render = require 'hogan-express'

api_host = 'api.github.com'
api_headers =
  'User-Agent': 'RocHack Account'

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
app.set 'partials', admin_contact: 'admin_contact'
app.engine 'html', hogan_render
app.engine 'eml', hogan_render
app.set 'views', __dirname + '/views'
app.use '/static', express.static __dirname + '/static'

app.get '/', (req, res) ->
  res.render 'index'

app.get '/login', (req, res) ->
  unless req.query.code
    console.log 'Redirecting to GitHub to get auth'
    # get oauth code
    res.redirect 'https://github.com/login/oauth/authorize?' + qs.stringify
      client_id: config.client_id
      state: req.session.state = unique_id()
      redirect_uri: 'http://account.rochack.org/login'
      scope: 'user'
  else
    console.log 'Got auth code from GitHub'
    # exchange oauth code for access_token
    body = qs.stringify
      client_id: config.client_id
      client_secret: config.client_secret
      code: req.query.code
    net.post 'github.com', '/login/oauth/access_token', null, api_headers, body, (status, data) ->
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

  console.log('create')

  unless token = req.session.access_token
    console.log('Redirecting to login')
    res.redirect 'login'
    return

  console.log('no redirect')

  res.locals = {}

  # got access_token
  query =
    'access_token': token
  console.log 'looking up user'
  net.get api_host, '/user', query, api_headers, null, (status, data) ->
    console.log 'got response', status, data
    user = try JSON.parse data
    if !user
      console.error 'Unable to get user', 'status': status, 'data:', data
      res.render 'create'
      return

    if !user.login or user.message?.indexOf('We had issues') == 0
      console.log 'github error'
      res.locals.github_error = true
      res.render 'create'
      return

    if !user.email
      res.locals.no_email = true
      res.render 'create'
      return

    username = user.login.toLowerCase()
    res.locals.username = username
    req.session.username = username
    user_stuff[username] =
      user: user

    console.log 'User', username, 'requesting an account'

    # check membership
    console.log 'checking membership'
    path = '/orgs/RocHack/public_members/' + qs.escape username
    net.get api_host, path, query, api_headers, null, (status, data) ->
      is_member = status == 204
      unless is_member
        # not a rochack member
        console.log 'user', username, 'is not a public member'
        res.locals.nonmember = true
        res.render 'create'
        return

      # check for existing account
      console.log 'checking for existing account'
      getent = child_process.spawn 'getent', ['passwd', username]
      getent.on 'exit', (code) ->
        if code == 0
          # account exists
          res.locals.duplicate = true
          console.error "User #{username} already has an account."
          res.render 'create'
        else
          # get keys
          path = "/users/#{qs.escape username}/keys"
          net.get api_host, path, query, api_headers, null, (status, data) ->
            if status != 200
              res.locals.key_error = true
              console.error 'Unable to import ssh keys', status, data
              res.end 'Unable to import ssh keys'
            else
              try keys = JSON.parse data
              unless keys[0]?.key
                res.locals.no_keys = true
              else
                res.locals.ok = true
                res.locals.name = user.name
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

  console.log 'Creating account...'
  useradd = child_process.spawn 'useradd', args
  useradd.stderr.on 'data', (data) ->
    console.error data.toString()
  useradd.on 'exit', (code) ->
    if code != 0
      #console.error 'useradd failed.'
      res.locals.fail = true
      res.render 'create2'
      return
    console.log 'Added user', username

    # account created.

    # set temporary password
    password = unique_id 12
    passwd = child_process.spawn 'chpasswd'
    passwd.stdin.end username + ':' + password
    passwd.on 'exit', (code) ->
      if code != 0
        console.error 'passwd failed for user', username
      else
        console.log 'Set password for', username
        res.locals.password = password

      # get uid
      id = child_process.spawn 'id', ['-u', username]
      id.stdout.on 'data', (data) ->
        uid = Number data.toString()
        gid = 1000

        # init home directory
        # todo: setuid/gid this script
        cmd = [
          'chmod 750 .'
          'mkdir .ssh'
          'chmod 700 .ssh'
          'touch .ssh/authorized_keys'
          'chmod 600 .ssh/authorized_keys'
          'touch .forward'
          "chown -R #{uid}:#{gid} .ssh .forward"
        ].join '; '

        child_process.exec cmd, cwd: home, (err, stdout, stderr) ->
          if stderr
            console.error stderr
          if err
            console.error 'exec error:', err
            res.locals.key_fail = true
            res.render 'create2'
            return

          # import ssh keys
          console.log 'Importing public keys...'
          fs.writeFile home + '/.ssh/authorized_keys', keys_str, (err) ->
            if err
              console.error err
              res.locals.key_fail = true
              res.render 'create2'
              return
            res.locals.key_success = true

            console.log 'Wrote authorized_keys for', username

            # set up email forwarding
            fs.writeFile home + '/.forward', user.email, (err) ->
              if err
                console.error err
                res.locals.forward_fail = true
              else
                console.log 'Wrote .forward:', user.email
                res.locals.forward_success = true
                res.locals.forward_address = user.email

              # tell them it worked
              res.render 'create2'

              notify = ->
                # notify user
                send_confirmation username, user, (err) ->
                  if !err
                    console.log 'Sent confirmation email'
                  else
                    console.log 'Error sending confirmation email', err

                # notify admin
                send_notification username, user, (err) ->
                  if !err
                    console.log 'Sent notification email'
                  else
                    console.log 'Error sending notification email', err

              # defer the emails to avoid a weird race condition with changing
              # the layout
              setTimeout notify, 100

send_email = (name, opts, cb) ->
  app.render name + '.eml', opts, (err, email) ->
    if err or !email
      return cb(err or 'Unable to render email')
    sendmail = child_process.spawn 'sendmail', ['-t', '-i']
    console.log 'sending email', email
    sendmail.stdin.end email
    sendmail.on 'exit', (code) ->
      if code != 0
        cb 'Sending email failed: ' + code
      else
        cb false

send_confirmation = (username, user, cb) ->
  opts =
    settings: layout: 'layout.eml'
    to: "#{user.name} <#{user.email}>"
    from: config.admin_email
    subject: 'RocHack Account'
    name: user.name
    username: username
  send_email 'confirmation', opts, cb

send_notification = (username, user, cb) ->
  opts =
    settings: layout: 'layout.eml'
    to: config.admin_email
    from: config.admin_email
    subject: 'RocHack Account Signup'
    name: user.name
    username: username
    email: user.email
    github_url: user.html_url
  send_email 'notification', opts, cb

port = config.port
app.listen port, '::'
console.log 'Listening on port', port
