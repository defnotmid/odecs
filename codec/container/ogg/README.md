# Ogg

Demuxing of one logical stream of an Ogg file (RFC 3533). Its main use is Ogg Opus (RFC 7845) through `movie.Reader`.

```odin
import ogg "../codec/container/ogg"

r: ogg.Reader
err := ogg.open(&r, "voice.opus", "OpusHead") // the stream whose first packet starts so
for i in 0 ..< len(r.packets) {
	data, e := ogg.read_packet(&r, i) // borrowed until the next read
	// r.packets.granule[i]: the page's granule position if packet i ends it, else -1
}
ogg.close(&r)
```

- **Indexing:** every page header is indexed at open through a 64 KiB window; payloads are not read. Packets are reassembled from their lacing, including packets that span pages.
- **Index layout:** a `#soa` table of packets, with byte spans per page.
- **Damage:** a packet left unfinished by a missing page is dropped, and lost sync resumes at the next capture pattern.
- **Not covered:** chained streams after the chosen stream ends are ignored, and page CRCs are not checked.
