# zigtorrent

Toy Bittorrent (original spec) CLI client that serves as a learning proyect for myself so its not expected to work optimally.  

## Features
- Download a piece
- Download a file
- Succesfully downloaded a [debian iso](https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/)
- Multithreaded (works but is a bit experimental)

## Todo
- Better piece selection
- Better peer selection and keeping track of them
- More testing (ie. torrents such as ubuntu iso don't work)
- Dont upload the entire file in memory. Just preallocate a file and seek and write to it.
- Multifile torrents
- Magnet links
- Support seeding
- DHT

## References
- https://wiki.theory.org/BitTorrentSpecification
- https://bittorrent.org/beps/bep_0003.html
- https://roadmap.sh/guides/torrent-client
- https://app.codecrafters.io/courses/bittorrent/overview
