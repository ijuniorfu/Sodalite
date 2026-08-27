# Roadmap

What is being built next, and nothing else. There are no dates on this page. Sodalite is built by
one person in his spare time, and a date here would be a guess wearing the costume of a promise.

The buckets, once they have content:

- **Next**: being designed or built right now
- **Later**: decided, not scheduled
- **Considering**: still an open question, feedback welcome
- **Not planned**: decided against, with the reason

Only buckets that hold something appear below. Everything else lives in
[Issues](https://github.com/superuser404notfound/Sodalite/issues) and
[Discussions](https://github.com/superuser404notfound/Sodalite/discussions). A request that is
not on this page has not been rejected, it has simply not been picked up yet.

## Next

### Offline downloads ([#81](https://github.com/superuser404notfound/Sodalite/issues/81))

Download movies and episodes to the device and play them back without a server connection:
commuting, flights, hotel wifi that only pretends to work. iPhone and iPad first, because that is
where a file on disk earns its storage.

Targeted at 1.1, the first release after 1.0.

## Later

### One home across every server ([#85](https://github.com/superuser404notfound/Sodalite/issues/85))

An opt-in mode that keeps more than one Jellyfin session alive at the same time and merges the
Home tab across them: one Continue Watching row in true chronological order, one My Media grid
holding every library from every box, and the Live TV tab present when any connected server has
a tuner. Search stays scoped to one server you pick, because merging relevance rankings from two
servers invents an order neither of them meant.

Off by default. With the switch off, Sodalite behaves exactly as it does today.

### Jump to a letter ([#86](https://github.com/superuser404notfound/Sodalite/issues/86))

A slim A to Z rail down the right edge of a library grid: move onto it, slide to P, and the grid
lands on the first title starting with P instead of coasting past ninety-five posters. Plex has
this on Apple TV and almost no other Jellyfin client does. It only means anything while a library
is sorted by title, so it appears with that sort and stays out of the way otherwise.
