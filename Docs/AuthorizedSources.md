# Authorized playback sources

Strimr checks the connected AllDebrid library first. A complete check with no exact ready file or matching processing magnet may then search **your configured authorized providers**. AllDebrid is a link processor, not a movie search engine. No indexer, paid source subscription, scraper, protected-stream extraction or default source provider is included.

## Setup

Open Settings → Playback → Authorized Playback Sources, or choose Set Up Sources from a missing-title playback sheet. Enter up to five HTTPS JSON endpoint URLs, one per line, and save. This opts into automatic submission of matching results to the connected AllDebrid account. Use providers and files you have permission to access. This initial adapter supports public HTTPS endpoints without credentials/query tokens; authenticated provider APIs need a dedicated secure adapter. Never put passwords or API keys in endpoint URLs.

The endpoint receives GET parameters `tmdb_id`, `kind` (`movie` or `tv`), `title`, `year`, and for TV `season` and `episode`. Return a JSON array such as:

```json
[{
  "tmdbID": 123,
  "kind": "movie",
  "year": 2025,
  "season": null,
  "episode": null,
  "filename": "Your Authorized Movie.2025.1080p.mp4",
  "link": "https://your-authorized-host/path/to/file",
  "authorized": true
}]
```

Use real IDs, metadata and authorized links. `authorized` is the provider's assertion, not independent rights verification. Mismatched TMDb ID/type/year/episode or filename is rejected. Responses are limited to 1 MiB and 50 entries per endpoint, five endpoints total; provider lookups are cached in memory for 60 seconds. At most three new candidates are submitted per availability pass; each AllDebrid client spaces API calls by at least 200 ms (five requests/second). Metadata is shared only with the endpoints you configure; AllDebrid credentials are never sent to providers.

## Your own links

On the missing-title playback sheet choose Add Authorized Link, paste a magnet URI (btih) or HTTP(S) download link, and confirm you have permission to access it. Movie/TV identity comes from the current details page and selected episode. Actual AllDebrid filenames must still match; movie imports require a matching year or explicit stable ID. Ambiguous generic filenames, wrong episodes, and combined episode files do not autoplay. Rename/identify your authorized files correctly rather than bypassing matching.

## Processing and playback

The implementation uses documented AllDebrid [`magnet/upload`, `link/unlock`, and `link/delayed`](https://docs.alldebrid.com/) endpoints. Cached magnets still go through status/files to select the correct actual file. Direct URLs use the returned filename and existing media-header validation. Delayed downloads are polled with the same foreground 10–30 second processing backoff (the documented minimum is five seconds). Missing/incomplete libraries use 30–60 seconds. Dismissal/background/account changes cancel work; authentication and rate-limit errors stop automatic polling. Resume, Simkl synchronization, quality fallback and the native player remain in the original pipeline.

Only account-scoped hashed magnet-submission receipts and magnet IDs/timestamps are persisted. Raw source URLs, resolved download URLs and API keys are not written to those receipts. Receipts prevent duplicate uploads after polling/relaunch, including ambiguous network failures. Strimr never automatically retries an uncertain upload: inspect your AllDebrid library before resubmitting. A newly submitted ID may take up to two minutes to appear; failed/ready-without-matching-file states do not play unrelated content. An accepted upload may continue in AllDebrid after leaving the app. Delayed download state/URLs remain memory-only; reopening may require adding that link again.

No live provider, account, file or playback is claimed verified by fixture-based tests. Signed-iPhone checks should cover authorized ready/pending magnets and links, delayed/error/rate-limited responses, wrong file/episode rejection, app background/relaunch, exact resume and Simkl updates.
