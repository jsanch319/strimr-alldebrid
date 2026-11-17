import Foundation

nonisolated enum TrailerEmbedConfiguration {
    /// YouTube's native WebView identity guidance explicitly uses https://<bundle identifier> as Referer/baseURL.
    static func origin(bundleID: String) -> URL? {
        guard bundleID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + bundleID.lowercased())
    }

    static func html(source: TrailerSource, origin: URL) -> String? {
        let content: String
        switch source {
        case let .youTube(id):
            guard id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
            content = """
            <div id="player"></div><script src="https://www.youtube.com/iframe_api"></script>
            <script>var player;function onYouTubeIframeAPIReady(){player=new YT.Player('player',{
            width:'100%',height:'100%',videoId:'\(id)',host:'https://www.youtube-nocookie.com',
            playerVars:{autoplay:0,playsinline:1,controls:1,loop:0,origin:'\(origin.absoluteString)'},
            events:{onError:function(e){window.webkit.messageHandlers.trailer.postMessage('YouTube error '+e.data);}}
            });}function pauseTrailer(){if(player&&player.pauseVideo){player.pauseVideo();}}</script>
            """
        case let .vimeo(id):
            guard id.range(of: "^[0-9]{1,15}$", options: .regularExpression) != nil else { return nil }
            content = """
            <iframe id="player" src="https://player.vimeo.com/video/\(id)?autoplay=0&loop=0" allow="fullscreen; picture-in-picture" allowfullscreen></iframe>
            <script>function pauseTrailer(){document.getElementById('player').contentWindow.postMessage({method:'pause'},'https://player.vimeo.com');}</script>
            """
        case .direct: return nil
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;width:100%;height:100%;background:#000}#player{width:100%;height:100%;border:0}</style>
        </head><body>\(content)</body></html>
        """
    }
}
