#!/usr/bin/env coffee                                                            
# signup.coffee - Account creation for RocHack members using GitHub oauth

qs = require 'querystring'
spawn = (require 'child_process').spawn
express = require 'express'
net = require './net'
config = require './config'

api_host = 'api.github.com'

app = express()

app.enable 'trust proxy'

#app.use app.router

# http://coffeescriptcookbook.com/chapters/strings/generating-a-unique-id
unique_id = (length=8) ->
  id = ""
  id += Math.random().toString(36).substr(2) while id.length < length
  id.substr 0, length

app.use express.bodyParser()
#app.use express.logger()
app.use express.methodOverride()
app.use express.cookieParser config.cookie_secret
app.use express.cookieSession
  'key': 'signup.connect.sess'
  'proxy': true

app.get '/', (req, res) ->
  unless req.session.access_token
    unless req.query.code
      # get oauth code
      res.redirect 'https://github.com/login/oauth/authorize?' + qs.stringify
        client_id: config.client_id
        state: req.session.state = unique_id()
        redirect_uri: 'http://account.rochack.org/'
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
            res.redirect '/'
          else
            res.end 'Error': + resp.error
          return
        if resp.token_type != 'bearer'
          console.error 'Strange token: ' + resp
          return

        req.session.access_token = resp.access_token
        res.redirect '/'
    return

  # got access_token
  query =
    'access_token': req.session.access_token
  #res.send 'looking up user'
  net.get api_host, '/user', query, null, null, (status, data) ->
    user = JSON.parse data
    username = user.login

    console.log 'User', username, 'requesting an account'

    # check membership
    #res.send 'checking membership'
    path = '/orgs/RocHack/public_members/' + qs.escape username
    net.get api_host, path, query, null, null, (status, data) ->
      is_member = status == 204
      if !is_member
        console.log 'user', username, 'is not a member'
        res.end 'Seems you are not a public member of the ' +
          '<a href="http://rochack.org/">RocHack</a> ' +
          'GitHub <a href="https://github.com/RocHack/">organization.</a> ' +
          'Get cracking!'
        return

      # check for existing account
      #res.send 'checking for existing account'
      passwd = spawn 'getent', ['passwd', username]
      passwd.on 'exit', (code) ->
        if code == 0
          # account exists
          res.end 'You already have an account, ' + username + '.'
          console.error "User #{username} already has an account."
          return

        # create account
        args = [
          '-m', '-N'
          '-s', '/bin/bash'
          '-g', 'rochack'
          '-G', 'users'
          username
        ]

        #res.send 'creating account'
        useradd = spawn 'useradd', args
        useradd.stderr.on 'data', (data) ->
          console.error data.toString()
        useradd.on 'exit', (code) ->
          if code != 0
            #console.error 'useradd failed.'
            return

          # done
          res.end 'Your account has been created, ' + username + '.'
          console.log 'Added user ' + username

          # notify admin
          #'', config.signup_notify_email
  return

app.listen 9001, '127.0.0.1'
console.log 'Listening on port 9001'
