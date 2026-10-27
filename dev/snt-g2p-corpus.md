# G2P gate corpora — provenance

The `dev/snt-g2p-gate.sh` corpus OOV gate runs the lexicon G2P over three
public-domain English novels (Project Gutenberg). The files are fetched at
gate time to `$G2P_CORPUS_DIR` (default `/tmp/g2p-corpus`) and are not
committed; verify a downloaded copy against these hashes before trusting a
gate result:

| file | source | sha256 |
|---|---|---|
| `pride_prejudice.txt` | https://www.gutenberg.org/files/1342/1342-0.txt | `81300b79e8a8d65ac530a97578417d06137e3bbc90622a10a65e5036183d2500` |
| `moby_dick.txt` | https://www.gutenberg.org/files/2701/2701-0.txt | `f12eb530502755ef2b8f535e2ecef3e95802eab584e60ac7992ccf856256fdbe` |
| `great_gatsby.txt` | https://www.gutenberg.org/cache/epub/64317/pg64317.txt | `ce760ec377accd352b41bb8f64504a72d7aa18ab3afb42ded2b56cecacf29e35` |

Fetched 2026-10-20. All three are US public domain (` ebooks posted
before 2026-01-01`). Re-download with:

    curl -fsSL <source> -o <file>

## Baseline numbers at the default threshold (0.25), 2026-10-20

| corpus | token OOV | clauses routed to espeak |
|---|---|---|
| Pride and Prejudice | 2.12% | 2.07% |
| Moby Dick | 2.53% | 4.26% |
| The Great Gatsby | 1.87% | 1.77% |

Moby Dick sits above the 3% clause target on archaic whaling vocabulary
and proper nouns (Queequeg, Tashtego, leviathan); the gate flags it as a
note rather than a failure because the listening A/B, not the rate, decides
whether per-clause mixing is audible. Levers if it matters: a wider
dictionary (the tables regenerate from misaki's gold/silver data) or a
higher `--g2p-oov-threshold` for that kind of text.

## French corpora (nano_lex_fr)

| file | role | source | sha256 |
|---|---|---|---|
| `fr_full.txt` | lexicon vocabulary (top 100k alpha forms) | https://github.com/hermitdave/FrequencyWords/raw/master/content/2018/fr/fr_full.txt | `dda23c3025fc195b3a7996af26371dcf3abd1aa2cd7218dbbb7c92a49780ab0c` |
| `meunier.txt` | lexicon supplement (literary) | https://www.gutenberg.org/cache/epub/13892/pg13892.txt (George Sand, Le meunier d'Angibault) | `ad7b1b2e7edf8687d209ecc33fed742eb165bc5939590c2344fc4f4b5c109049` |
| `balzac1.txt` | lexicon supplement (literary) | https://www.gutenberg.org/cache/epub/41211/pg41211.txt (Balzac, La Comedie humaine v01) | `c192ed74d4ffd4000497033b8a512e9f5ca805531281d5395259f954c12e30d2` |
| `miserables1.txt` | HELD-OUT eval corpus (never in the lexicon) | https://www.gutenberg.org/cache/epub/17489/pg17489.txt (Hugo, Les miserables T1: Fantine) | `a5de514ba7b9f2e1790e7e259c4e8b7a35ae1d29e4bf9a5f8767039c58b80503` |

Fetched 2026-10-20. The lexicon values are espeak-ng `-q --ipa -v fr`
output, so in-dictionary words are espeak-exact by construction; OOV words
speak through the rule layer in nano_lex_fr.c (unlike English, French OOV
is never silent), and clauses above the OOV threshold still fall back to
espeak. Numbers on the held-out novel at the default threshold 0.25
(2026-10-20, 107077-entry lexicon): token OOV 2.69%, clauses routed to
espeak 2.03%.
