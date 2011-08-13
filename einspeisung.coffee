#!/usr/bin/env coffee

express = require 'express'

{waterfall, map} = require 'async'
{Database} = require 'sqlite'

db = new Database()

server = express.createServer()

http = require 'http'
{parse} = require 'url'

libxmljs = require 'libxmljs'

jquery = require 'jquery'

{puts} = require 'sys'
{inspect} = require 'util'

get = require 'get'

_ = require 'underscore'

{Iconv} = require 'iconv'

concatBuffer = (buffers) ->
    len = 0
    for buffer in buffers
        len += buffer.length
    body = new Buffer len
    pos = 0
    for buffer in buffers
        buffer.copy body, pos
        pos += buffer.length
    body

fetchUrl = (url, cb) ->
    u = parse url
    http.get {host: u.host, path: u.pathname}, (res) ->
        if (res.statusCode - res.statusCode % 100) / 100 == 3
            fetchUrl res.headers.location, cb
            return
        unless res.statusCode == 200
            cb res.statusCode
            return
        buffers = [] 
        res.on 'error', -> cb "Err", url
        res.on 'data', (buffer) -> buffers.push buffer
        res.on 'end', ->
            data = concatBuffer buffers
            cs = /charset=(.*)/.exec(res.headers["content-type"])
            if cs
                data = new Iconv(cs[1], "UTF-8").convert(data).toString 'utf8'

            cb null, url, data.toString 'utf8'

fetchUrlWithCache = (url, cb) -> waterfall [
    (cb) -> db.execute 'SELECT b FROM mapping WHERE a = ?', [url], cb
    (rows, cb) ->
        url_red = if rows and rows.length > 0 then rows[0].b else url
        db.execute 'SELECT content FROM content WHERE url = ?', [url_red], (err, rows) ->
            cb err, url_red, rows
    (url_red, rows, cb2) -> if rows and rows.length > 0
        cb null, url_red, rows[0].content
    else
        puts "GET #{url}"
        fetchUrl url, cb2
    (url_red, content, cb) ->
        db.execute 'INSERT INTO content (url, content) VALUES (?, ?)', [url_red, content], (err) ->
            cb err, url_red, content
    (url_red, content) ->
        if url_red != url
            db.execute 'INSERT INTO mapping (a, b) VALUES (?, ?)', [url, url_red], (err) ->
                cb err, url_red, content
        else
            cb null, url_red, content
    ], cb

server.get '/', (req, res, next) ->
    res.header("Content-Type", "application/xhtml+xml")
    dom = null
    waterfall [
        (cb) -> fetchUrl req.query.feed, cb
        (url, xml, cb) ->
            dom = libxmljs.parseXmlString xml.replace(/^<?[^?]*?>/, '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
            if dom.get '/rss'
                ops =
                    getItems: (dom) -> dom.find '//item', {}
                    getUrl: (node) -> node.get('link').text()
                    setText: (node, text) -> node.get('description')?.text text

            atom = a: 'http://www.w3.org/2005/Atom'
            if dom.get '/a:feed', atom
                ops =
                    getItems: (dom) -> dom.find '//a:entry', atom
                    getUrl: (node) -> node.get('a:link', atom).attr('href').value()
                    setText: (node, text) -> if summary = node.get 'summary'
                            summary.text text
                        else
                            node.addChild new libxmljs.Element node.doc(), "summary", type: "html", text
            dom.get('/*').attr 'xml:base': url.replace /[^\/]*$/, ""
            items = for node in ops.getItems dom
                {
                    ops: ops
                    url: ops.getUrl node
                    dom: node
                }
            map items, (item, cb) ->
                fetchUrlWithCache item.url, (err, redirect, content) ->
                    item.redirect = redirect
                    item.content = content
                    cb err, item
            , cb
        (items, cb) ->
            map items, (item, cb) ->
                parsed = jquery item.content
                unless req.query.pagination
                    item.contents = [parsed]
                    cb null, item
                    return

                pages = _.uniq(parsed.find(req.query.pagination).find("a").map -> @href)

                pages = for page in pages
                    if /^\//.exec page
                        /^([a-z]+):\/\/[^\/]+/.exec(item.redirect)[0] + page

                pages = _.without pages, item.url, item.redirect

                map pages, (page, cb) ->
                    fetchUrlWithCache page, (err, redirect, content) -> cb err, content 
                , (err, contents) ->
                    if err
                        cb err
                        return

                    item.contents = [parsed]
                    for content in contents
                        item.contents.push jquery content
                    cb err, item
            , cb
        (items, cb) ->
            for item in items
                elements = for content in item.contents
                    wanted = content.find req.query.path
                    if req.query.ignore
                        wanted.find(req.query.ignore).remove()
                    wanted.html()
                item.ops.setText item.dom, elements.join(' ').replace /[<>&]/g, (char) -> switch char
                    when "<" then "&lt;"
                    when ">" then "&gt;"
                    when "&" then "&amp;"
            res.send dom.toString()
            # res.send (jquery(req.query.path, a.content).html() for a in pages).join '\n'
    ], (err) -> if err
        res.send inspect err

waterfall [
    (cb) -> db.open "content.sqlite3", cb
    (cb) ->
        server.listen 8080
        cb null
]
