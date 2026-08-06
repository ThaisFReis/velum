# PDF sources

The three PDFs in `docs/` are rendered from the HTML in this folder:

| Source | Output |
|---|---|
| `whitepaper.html` | `docs/Velum-Whitepaper-v0.1.pdf` |
| `deck.html` | `docs/Velum-Deck.pdf` |
| `onepage.html` | `docs/Velum-OnePage.pdf` |

```bash
chromium --headless --disable-gpu --no-pdf-header-footer \
  --print-to-pdf=docs/Velum-Whitepaper-v0.1.pdf docs/src/whitepaper.html
```

These files are tracked for a reason. They used to live outside the repository, and because the
numbers a reader sees live *here* and not in the Markdown, the two drifted without any `grep` over
the repo being able to notice. By the time it was caught, the deck claimed 66 tests against an
actual 69 and five upstream findings against seven, and the whitepaper PDF was missing the
scalar-field paragraph (§11.7) entirely while stating 5/5 tests for a package that has 9.

**`whitepaper.html` is not generated from `WHITEPAPER.md`** — it is a hand-built parallel document.
Any edit to one must be made in the other. To check they still agree, extract the text and diff it;
`docs/IMPLEMENTATION.md` §6.6 records how, and what it found.
