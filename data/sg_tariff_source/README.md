# Singapore tariff source

Singapore publishes **no machine-readable tariff file**. The only source for the
Trade Classification, Customs and Excise Duties (STCCED) is a single PDF:

- Download: <https://file.go.gov.sg/stcced2022.pdf>
- Linked from: <https://www.customs.gov.sg/doing-business/business-resources/hs-classification-of-goods/understanding-hs-classification/>
- 2022 edition, 655 pages, HS 2022 nomenclature. This is the current edition.
- `sha256 1df940ad26e07a4cdeaa76a166225e928bd2651d35e9506df0c417fd1a8769e0`
  (also recorded in `config/jurisdictions/sg_revisions.csv` and in the notes
  manifest, so a re-download can be checked against it)

So there is no acquire adapter and no scheduled refresh for SG. Fetch the PDF by
hand into `.sg_download/` (gitignored — it is 11 MB) and run:

```bash
python3 scripts/hts_automation/parse_sg_stcced.py \
    data/sg_tariff_source/.sg_download/stcced2022.pdf
```

That writes, and the gates must pass before it writes anything:

| Path | Tracked | What it is |
|---|---|---|
| `sg_tariff_2022_rev_101.csv` | yes | canonical rows for `build_hts_corpus.load_rows_sg()` |
| `sg_tariff_2022_rev_101.csv.meta.json` | yes | effective date and source, read by `acquire/manual.py` |
| `sg_2022_rev_101.reference.json` | yes | abbreviations, symbols, the 14 units of quantity |
| `sg_2022_rev_101.toc.json` | yes | contents-page section/chapter titles + printed start pages |
| `../hts_notes/sg_2022_rev_101/sg_2022_rev_101.notes.json` | no (gitignored) | cite_id → note record sidecar |
| `../hts_notes/sg_2022_rev_101/sg_2022_rev_101.notes.{gri,section,chapter}.jsonl` | no | Pinecone note families |
| `../hts_notes/sg_2022_rev_101/sg_2022_rev_101.notes.manifest.json` | yes | counts + hashes |
| `scripts/hts_automation/chapters_sg.json` | yes | chapter/section index, read from the book |

Then the explorer dataset and the retrieval corpus, from that CSV:

```bash
python3 scripts/hts_automation/build_explorer_dataset.py \
    data/sg_tariff_source/sg_tariff_2022_rev_101.csv \
    --source-format sg --jurisdiction SG \
    --out output/sg_2022_rev_101/sg_2022_revision_101.json

python3 scripts/hts_automation/build_hts_corpus.py \
    data/sg_tariff_source/sg_tariff_2022_rev_101.csv \
    scripts/hts_automation/chapters_sg.json \
    output/sg_2022_rev_101/sg_2022_rev_101 \
    --jurisdiction SG --revision 2022 --source-format sg --max-depth 8
```

## What the 2022 edition contains

14,460 codes (1,230 headings, 1,976 six-digit, 11,253 eight-digit) plus 2,278
uncoded condition rows, over 636 printed pages. 11,423 leaves, every one of them
carrying a unit of quantity and no non-leaf carrying one — the tree rebuilt from
the printed dash depth and Singapore's own unit column agree exactly.

Duty is charged on very little: of 14,460 codes, **8** carry a full customs duty
(beer and samsu), **16** a preferential rate and **597** an excise duty
(chapters 21, 22, 24, 27, 33, 38 and 87). A blank duty column means the rate is
nil, not that the source is silent.

Legal notes: 21 section-note blocks, 96 `Note(s).` blocks, 38
`Subheading Note(s).` blocks → 480 note records, plus the six General
Interpretative Rules with the worked examples Singapore prints under them.
