#!/usr/bin/env python3
# Web proxy for OmniWeb 2.7 in NeXTSTEP 3.3 (Previous emulator), a 1997 browser: HTTP/1.0 and HTML 3.2, no HTTPS,
# CSS or JavaScript. The proxy runs on the Mac and stands between it and today's web:
#   • fetches every page over HTTPS (plain HTTP where a host has no HTTPS) and hands it over as plain HTTP;
#   • cuts pages down to HTML 3.2: scripts, styles, SVG, frames and media go, as do tags and attributes the
#     browser doesn't know; text becomes ISO Latin-1;
#   • turns every image but GIF into a JPEG no larger than 800 pixels (sips).
#   ./webproxy.py      listens on 127.0.0.1:3128, which NeXTSTEP reaches as 10.0.2.2:3128 (Previous' SLiRP network)
# Two ways to use it from the browser:
#   • as a gateway, nothing to set up: open http://10.0.2.2:3128/ (a start page: address, web search, a few
#     sites). Pages are at http://10.0.2.2:3128/http://host/path and all their links lead back through it.
#   • as an HTTP proxy at 10.0.2.2 port 3128, for a browser set to use one: pages keep their own addresses.
import gzip, html, re, subprocess, tempfile, unicodedata, urllib.error, urllib.parse, urllib.request
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 3128
AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
HOME = """<html><head><title>NeXT Web Proxy</title></head><body>
<h1>NeXT Web Proxy</h1>
<form action="%(gate)sgo" method="get">
Address: <input type="text" name="url" size="50"> <input type="submit" value="Open">
</form>
<form action="%(gate)shttp://html.duckduckgo.com/html/" method="get">
Search the web: <input type="text" name="q" size="40"> <input type="submit" value="Search">
</form>
<ul>
<li><a href="%(gate)shttp://en.wikipedia.org/">Wikipedia</a>
<li><a href="%(gate)shttp://lite.cnn.com/">CNN (text)</a>
<li><a href="%(gate)shttp://text.npr.org/">NPR (text)</a>
<li><a href="%(gate)shttp://news.ycombinator.com/">Hacker News</a>
</ul>
</body></html>
"""
GIF = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"

# MARK: Pages

# The tags the browser gets (HTML 3.2); other tags are dropped and their contents kept.
KEEP = set("""a address b big blockquote body br caption center cite code dd dfn dir div dl dt em font form
    h1 h2 h3 h4 h5 h6 head hr html i img input kbd li menu ol option p pre samp select small strike strong sub sup
    table td textarea th title tr tt u ul var""".split())
RENAME = {"s": "strike", "del": "strike", "ins": "u", **{tag: "div" for tag in
          "section article header footer nav main aside figure figcaption details summary fieldset".split()}}
VOID = {"br", "hr", "img", "input"}
# Dropped with everything inside them.
DROP = {"script", "style", "svg", "template", "iframe", "object", "video", "audio", "canvas"}
ATTRIBUTES = set("""href src alt name value type action method checked selected size maxlength rows cols multiple
    colspan rowspan align valign border""".split())
INPUTS = {"text", "password", "checkbox", "radio", "submit", "reset", "hidden", "image", "file"}
PLAIN = str.maketrans({"\u2018": "'", "\u2019": "'", "\u201c": '"', "\u201d": '"', "\u2013": "-", "\u2014": "--",
                       "\u2026": "...", "\u2022": "*", "\u2192": "->", "\u2190": "<-", "\u2122": "(TM)",
                       "\u20ac": "EUR", "\u2009": " ", "\u202f": " ", "\u200b": "", "\ufeff": ""})


def http(url):
    """The browser only speaks http."""
    return re.sub("^https:", "http:", url, flags=re.I)


class Simplifier(HTMLParser):
    def __init__(self, base, prefix):
        super().__init__()
        self.base, self.prefix = base, prefix   # the page's address; what the gateway puts before every address
        self.out = []
        self.skip, self.depth = None, 0     # inside a DROP tag, and how many of it are open
        self.button = None                  # inside <button>: (its attributes, its text so far)
        self.form = False                   # inside <form>

    def handle_starttag(self, tag, attrs):
        if self.skip:
            self.depth += tag == self.skip
            return
        if tag in DROP:
            self.skip, self.depth = tag, 1
            return
        attrs = dict(attrs)
        if tag == "button":
            self.button = (attrs, [])
        if tag == "base" and attrs.get("href"):
            self.base = self.absolute(attrs["href"])
        tag = RENAME.get(tag, tag)
        if tag not in KEEP or self.button:
            return
        self.form = self.form or tag == "form"
        if tag == "img":
            attrs["src"] = attrs.get("data-src") or attrs.get("data-lazy-src") or attrs.get("src")   # lazy loading
            if (attrs.get("src") or "data:").startswith("data:"):
                return
        if tag == "input" and (attrs.get("type") or "text").lower() not in INPUTS:
            attrs["type"] = "text"
        self.emit(tag, attrs)

    def handle_endtag(self, tag):
        if self.skip:
            self.depth -= tag == self.skip
            if not self.depth:
                self.skip = None
        elif tag == "button" and self.button:
            # HTML 3.2 has no <button>: in a form, a submit button with its text (elsewhere it only runs scripts)
            attrs, text = self.button
            self.button = None
            if self.form and (attrs.get("type") or "submit").lower() == "submit":
                value = attrs.get("value") if attrs.get("name") else " ".join("".join(text).split()) or "Submit"
                self.emit("input", {"type": "submit", "name": attrs.get("name"), "value": value})
        elif not self.button:
            self.form = self.form and tag != "form"
            tag = RENAME.get(tag, tag)
            if tag in KEEP and tag not in VOID:
                self.out.append("</%s>" % tag)

    def handle_data(self, data):
        if self.button:
            self.button[1].append(data)
        elif not self.skip:
            self.out.append(html.escape(data, quote=False))

    def absolute(self, url):
        try:
            return urllib.parse.urljoin(self.base, url.strip())
        except ValueError:
            return url

    def emit(self, tag, attrs):
        self.out.append("<" + tag)
        for name, value in attrs.items():
            if name not in ATTRIBUTES or (value is None and name in ("name", "value")):
                continue
            if name in ("href", "src", "action") and not (value or "").startswith("#"):
                # in full, as http, and through the gateway
                value = http(self.absolute(value or ""))
                if value.startswith("http:"):
                    value = self.prefix + value
            self.out.append(" " + name if value is None else ' %s="%s"' % (name, html.escape(value)))
        self.out.append(">")


def simplify(page, base, prefix):
    """A page as HTML 3.2 in ISO Latin-1."""
    simplifier = Simplifier(base, prefix)
    simplifier.feed(page)
    simplifier.close()
    return unicodedata.normalize("NFC", "".join(simplifier.out)).translate(PLAIN).encode("latin-1", "replace")


def decode(data, charset):
    charset = charset or (re.search(rb"charset=[\"']?([\w-]+)", data[:4096]) or [b"", b"utf-8"])[1].decode()
    try:
        return data.decode(charset, "replace")
    except LookupError:
        return data.decode("utf-8", "replace")


def jpeg(data):
    """An image as a JPEG no larger than 800 pixels (an empty GIF if sips can't read it) → (data, content type)."""
    with tempfile.TemporaryDirectory() as folder:
        source, result = folder + "/in", folder + "/out.jpg"
        with open(source, "wb") as file:
            file.write(data)
        size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", source], capture_output=True, text=True).stdout
        shrink = ["-Z", "800"] if max(map(int, re.findall(r"pixel\w+: (\d+)", size)), default=0) > 800 else []
        if subprocess.run(["sips", "-s", "format", "jpeg", *shrink, source, "--out", result], capture_output=True).returncode:
            return GIF, "image/gif"
        with open(result, "rb") as file:
            return file.read(), "image/jpeg"


# MARK: Fetching

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Redirects go back to the browser, so that it knows the page's real address."""
    def redirect_request(self, *args):
        return None


opener = urllib.request.build_opener(NoRedirect)
plain = set()   # hosts without HTTPS


def fetch(url, prefix, method, body, headers):
    """Fetches the http:// address the browser asked for → (status, headers, body) for the browser.
    prefix: what goes before every address the browser gets (the gateway's address, or nothing for the proxy)."""
    parts = urllib.parse.urlsplit(url)
    scheme = "http" if parts.port or parts.hostname in plain else "https"
    target = urllib.parse.urlunsplit((scheme,) + parts[1:])
    try:
        response = opener.open(urllib.request.Request(target, data=body, method=method, headers=headers), timeout=20)
    except urllib.error.HTTPError as error:
        response = error    # redirects and error pages are answers too
    except urllib.error.URLError:
        if scheme == "http":
            raise
        plain.add(parts.hostname)
        return fetch(url, prefix, method, body, headers)
    data = response.read()
    if response.headers.get("Content-Encoding") == "gzip":
        data = gzip.decompress(data)
    kind = response.headers.get_content_type()
    if kind in ("text/html", "application/xhtml+xml"):
        data, kind = simplify(decode(data, response.headers.get_content_charset()), url, prefix), "text/html"
    elif kind.startswith("image/") and kind != "image/gif" and data:
        data, kind = jpeg(data)
    reply = [("Content-Type", kind)]
    location = response.headers.get("Location")
    if location:
        location = urllib.parse.urljoin(target, location)
        if not parts.port and location == ("http" if scheme == "https" else "https") + target[len(scheme):]:
            # the host sends its HTTPS (or HTTP) address to the other one: remember which it wants and ask again
            (plain.add if scheme == "https" else plain.discard)(parts.hostname)
            return fetch(url, prefix, method, body, headers)
        reply.append(("Location", prefix + http(location)))
    for cookie in response.headers.get_all("Set-Cookie") or []:
        cookie = re.sub(r";\s*Secure\b", "", cookie, flags=re.I)
        if prefix:  # the gateway is one host to the browser: keep each site's cookies to that site's addresses
            cookie = re.sub(r";\s*(domain|path)=[^;]*", "", cookie, flags=re.I) + "; Path=/http://%s/" % parts.netloc
        reply.append(("Set-Cookie", cookie))
    if response.headers.get("WWW-Authenticate"):
        reply.append(("WWW-Authenticate", response.headers["WWW-Authenticate"]))
    return response.status, reply, data


class Proxy(BaseHTTPRequestHandler):
    def do_GET(self):
        gate = "http://%s/" % (self.headers["Host"] or "10.0.2.2:%d" % PORT)
        # proxy: GET http://host/path; gateway: GET /http://host/path
        match = re.match("(/?)https?:/+(.+)", self.path, re.I)
        if not match:
            request = urllib.parse.urlsplit(self.path)
            address = urllib.parse.parse_qs(request.query).get("url", [""])[0].strip()
            if request.path == "/go" and address:   # the start page's Address field
                return self.reply(302, [("Location", gate + http(address if "://" in address else "http://" + address))], b"")
            return self.reply(200, [("Content-Type", "text/html")], (HOME % {"gate": gate}).encode())
        url = "http://" + match[2]
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) or None
        headers = {name: self.headers[name] for name in ("Cookie", "Authorization", "Content-Type", "Accept-Language") if self.headers[name]}
        headers.update({"User-Agent": AGENT, "Accept-Encoding": "gzip"})
        try:
            self.reply(*fetch(url, gate if match[1] else "", self.command, body, headers))
        except Exception as error:
            page = "<html><body><h1>The proxy couldn't get this page</h1><p>%s<p>%s</body></html>" % (html.escape(url), html.escape(str(error)))
            self.reply(502, [("Content-Type", "text/html")], page.encode("latin-1", "replace"))

    do_POST = do_HEAD = do_GET

    def reply(self, status, headers, body):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Proxy).serve_forever()
