#!/usr/bin/env coffee

async = {waterfall, map, mapSeries} = require 'async'
express = require 'express'
get = require 'get'
http = require 'http'
iconv = {Iconv} = require 'iconv'
jquery = require 'jquery'
libxmljs = require 'libxmljs'
sqlite = {Database} = require 'sqlite'
sys = {puts} = require 'sys'
underscore = _ = require 'underscore'
url = {parse} = require 'url'
util = {inspect} = require 'util'

db = new Database()
server = express.createServer()

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

fetchUrlWithCache = (url, tag, cb) -> waterfall [
    (cb) -> db.execute 'SELECT b FROM mapping WHERE a = ?', [url], cb
    (rows, cb) ->
        url_red = if rows and rows.length > 0 then rows[0].b else url
        db.execute 'SELECT cache_tag, content FROM content WHERE url = ?', [url_red], (err, rows) ->
            cb err, url_red, rows
    (url_red, rows, cb2) -> 
        if rows and rows.length > 0
            if rows[0].cache_tag == tag
                cb null, url_red, rows[0].content
                return

            db.execute 'DELETE from content WHERE url = ?', [url_red], (err, rows) -> cb2 err
        cb2 null
    (cb) ->
        puts "GET #{url}"
        fetchUrl url, cb
    (url_red, content, cb) ->
        if content.length == 0
            cb "Received empty content"
            return
        db.execute 'INSERT INTO content (url, cache_tag, content) VALUES (?, ?, ?)', [url_red, tag, content], (err) ->
            cb err, url_red, content
    (url_red, content) ->
        if url_red != url
            db.execute 'INSERT INTO mapping (a, b) VALUES (?, ?)', [url, url_red], (err) ->
                cb err, url_red, content
        else
            cb null, url_red, content
    ], cb

escapeHtml = (html) -> html.replace /[<>&]/g, (char) -> switch char
                    when "<" then "&lt;"
                    when ">" then "&gt;"
                    when "&" then "&amp;"

class RssFeed
    constructor: (@dom) ->
    items: -> new RssItem node for node in @dom.find '//item', {}

class RssItem
    constructor: (@node) ->
        @url = node.get('link').text()
        @date = node.get('pubDate').text()
    text: (text) -> @node.get('description')?.text text

nsAtom = a: 'http://www.w3.org/2005/Atom'
class AtomFeed
    constructor: (@dom) ->
    items: -> new AtomItem node for node in @dom.find '//a:entry', nsAtom

class AtomItem
    constructor: (@node) ->
        @url = node.get('a:link', nsAtom).attr('href').value()
        @date = node.get('a:updated', nsAtom).text()
    text: (text) -> if summary = @node.get 'summary'
            summary.text text
        else
            @node.addChild new libxmljs.Element @node.doc(), "summary", type: "html", text

server.get '/', (req, res, next) ->
    if req.query.page
        res.partial 'page.jade', req.query
        return

    res.header("Content-Type", "application/xhtml+xml")
    doc = null
    waterfall [
        (cb) -> fetchUrl req.query.feed, cb
        (url, xml, cb) ->
            dom = libxmljs.parseXmlString xml.replace(/^<?[^?]*?>/, '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
            dom.get('/*').attr 'xml:base': url.replace /[^\/]*$/, ""
            if dom.get '/rss'
                doc = new RssFeed dom
            else if dom.get '/a:feed', nsAtom
                doc = new AtomFeed dom

            items = doc.items()
            mapSeries items, (item, cb) ->
                fetchUrlWithCache item.url, item.date, (err, redirect, content) ->
                    item.redirect = redirect
                    item.content = content
                    cb err, item
            , cb
        (items, cb) ->
            mapSeries items, (item, cb) ->
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
                    fetchUrlWithCache page, item.date, (err, redirect, content) -> cb err, content 
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
                item.text escapeHtml elements.join ' '
            res.send doc.dom.toString()
    ], (err) -> if err
        res.send inspect err

waterfall [
    (cb) -> db.open "content.sqlite3", cb
    (cb) ->
        server.listen 8080
        cb null
]
