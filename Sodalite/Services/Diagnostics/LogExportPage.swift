import Foundation

/// The page a phone or laptop gets when it opens the export link (Sodalite#148).
///
/// Self-contained by requirement, not by preference: the device that opens this may have no route to
/// the internet at all, and a log that needs a CDN to be readable is not a local export. Everything is
/// inline, and `LogExportSessionTests` pins that no URL to another origin survives an edit here.
///
/// The second constraint is the one that decides whether the feature works. The page is served over
/// plain HTTP from a LAN address, which is not a secure context, so `navigator.clipboard` is undefined
/// in Safari. A copy button wired to it alone is a button that silently does nothing, which is a worse
/// place to be than the screenshots this replaces, so the `execCommand` path is the real one and the
/// modern API is the optimization.
nonisolated enum LogExportPage {

    /// `download` is the text below as a file, the download a reader expects from this page.
    /// `persistedLog` is the file sink's file when there is one: a link and not inline, because it runs to
    /// 32 MB and a phone that renders that into a `pre` stops responding. It is a different log (only
    /// what was written while the switch was on, across launches), so it is labelled as one and says so
    /// underneath: Sodalite#164 was a reporter who took it for the page's own download.
    static func render(
        document: String,
        token: String,
        download: String,
        persistedLog: (path: String, length: Int)? = nil
    ) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(languageTag)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(String(localized: "settings.log.title")))</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        <h1>\(escape(String(localized: "settings.log.title")))</h1>
        <div class="actions">
        <button id="copy" type="button">\(escape(String(localized: "settings.log.export.page.copy")))</button>
        <a class="button" href="\(escape(download))" download>\(escape(String(localized: "settings.log.export.page.download")))</a>
        <a class="button" href="/\(token)/log.txt">\(escape(String(localized: "settings.log.export.page.text")))</a>
        \(persistedLogLink(persistedLog))</div>
        <p id="status" role="status" aria-live="polite"></p>
        \(persistedLogNote(persistedLog))        <p class="note">\(escape(String(localized: "settings.log.export.page.note")))</p>
        <pre id="log">\(escape(document))</pre>
        </main>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    private static func persistedLogLink(_ file: (path: String, length: Int)?) -> String {
        guard let file else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.length), countStyle: .file)
        let title = String(format: String(localized: "settings.log.export.page.file"), size)
        return "<a class=\"button\" href=\"\(escape(file.path))\" download>\(escape(title))</a>\n"
    }

    private static func persistedLogNote(_ file: (path: String, length: Int)?) -> String {
        guard file != nil else { return "" }
        return "<p class=\"note\">\(escape(String(localized: "settings.log.export.page.file.note")))</p>\n"
    }

    /// Only reachable by a connection already in flight when the deadline passed: the listener closes
    /// itself, so a later reload is a refused connection rather than this. It still says the one thing
    /// the reader needs, and carries no log.
    static func expired() -> String {
        """
        <!DOCTYPE html>
        <html lang="\(languageTag)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(String(localized: "settings.log.title")))</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        <h1>\(escape(String(localized: "settings.log.export.expired.title")))</h1>
        <p class="note">\(escape(String(localized: "settings.log.export.page.expired.message")))</p>
        </main>
        </body>
        </html>
        """
    }

    /// The app's language, so a German reporter gets a German page. Stripped to the primary subtag
    /// because that is what `lang` wants and what the strings were translated against.
    private static var languageTag: String {
        let identifier = Locale.preferredLanguages.first ?? "en"
        return escape(String(identifier.prefix { $0 != "-" && $0 != "_" }))
    }

    /// A log line is a file name, a server error or a URL, so it is arbitrary text. Unescaped it can
    /// close the `pre` and run as markup.
    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Dark because the thing being read is a log, and `overflow-wrap` because the lines are URLs and a
    /// phone that scrolls sideways per line cannot be read at all.
    private static let style = """
        :root { color-scheme: dark; }
        body {
          margin: 0;
          padding: 16px;
          background: #101014;
          color: #e8e8ea;
          font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        }
        main { max-width: 900px; margin: 0 auto; }
        h1 { font-size: 20px; margin: 8px 0 16px; }
        .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 12px; }
        button, .button {
          -webkit-appearance: none;
          appearance: none;
          display: inline-block;
          padding: 12px 20px;
          border: 0;
          border-radius: 12px;
          background: #2d6df6;
          color: #fff;
          font: inherit;
          font-weight: 600;
          text-decoration: none;
          cursor: pointer;
        }
        .button { background: rgba(255,255,255,0.12); }
        #status { min-height: 1.4em; margin: 0 0 8px; font-weight: 600; color: #4ad07a; }
        #status.error { color: #ff6b6b; }
        .note { margin: 0 0 16px; color: #9a9aa2; font-size: 13px; }
        pre {
          margin: 0;
          padding: 12px;
          border-radius: 12px;
          background: #000;
          color: #d8d8dc;
          font: 12px/1.5 ui-monospace, Menlo, monospace;
          white-space: pre-wrap;
          overflow-wrap: anywhere;
          -webkit-user-select: text;
          user-select: text;
        }
        """

    /// `execCommand` first is not a style choice: over http the modern API is not there, and when it is
    /// there it can still reject a call Safari did not consider user-initiated. Both paths end in the
    /// same visible answer, and a failure says what to do by hand rather than nothing.
    private static let script = """
        (function () {
          var button = document.getElementById('copy');
          var log = document.getElementById('log');
          var status = document.getElementById('status');
          var done = \(jsString(String(localized: "settings.log.export.page.copied")));
          var failed = \(jsString(String(localized: "settings.log.export.page.copyFailed")));

          function report(text, isError) {
            status.textContent = text;
            status.className = isError ? 'error' : '';
          }

          function selectLog() {
            var range = document.createRange();
            range.selectNodeContents(log);
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
          }

          button.addEventListener('click', function () {
            selectLog();
            var copied = false;
            try {
              copied = document.execCommand('copy');
            } catch (error) {
              copied = false;
            }
            if (copied) {
              report(done, false);
              return;
            }
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(log.textContent).then(function () {
                report(done, false);
              }, function () {
                report(failed, true);
              });
              return;
            }
            report(failed, true);
          });
        })();
        """

    /// A translated string goes into the script as a JSON string literal, so an apostrophe in French or
    /// a quote in German cannot end the literal and the rest of the page with it. `<` is escaped on top
    /// of that, because JSON leaves it alone and a `</script>` inside a string still closes the element
    /// it sits in, whatever the quoting around it says.
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // JSONSerialization needs a container; unwrap the single element back out of it.
        return String(array.dropFirst().dropLast()).replacingOccurrences(of: "<", with: "\\u003C")
    }
}
