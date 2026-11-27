# tg_split.jq: split $text (from --rawfile) into Telegram-sized messages.
# Read raw text with --rawfile, not -R: jq 1.7 and 1.7.1 corrupt a multibyte
# character that straddles a 4096-byte boundary on raw stdin.
# $limit is measured in UTF-16 code units, the unit Telegram counts, so an
# emoji outside the BMP costs 2. Prefers blank-line boundaries, then line
# ends, then splits an over-long line by code point. Every chunk is followed
# by a NUL. Chunks with no visible characters are never emitted.

def width: if . > 65535 then 2 else 1 end;
def units: reduce explode[] as $c (0; . + ($c | width));

# One over-long line -> pieces of at most $limit units.
def hard_split:
  reduce explode[] as $c ({done: [], cur: [], n: 0};
    ($c | width) as $w
    | if .n + $w > $limit and .n > 0
      then .done += [.cur] | .cur = [$c] | .n = $w
      else .cur += [$c] | .n += $w
      end)
  | (.done + [.cur]) | map(implode);

# [[text, units], ...] -> [text, ...], joining neighbours with $sep while
# the result still fits.
def pack($sep):
  ($sep | units) as $sw
  | reduce .[] as $p ({done: [], cur: null, n: 0};
      if .cur == null then .cur = $p[0] | .n = $p[1]
      elif .n + $sw + $p[1] <= $limit then .cur += $sep + $p[0] | .n += $sw + $p[1]
      else .done += [.cur] | .cur = $p[0] | .n = $p[1]
      end)
  | .done + (if .cur == null then [] else [.cur] end);

def with_units: [., units];

# One paragraph -> pieces that each fit.
def fit_paragraph:
  if units <= $limit then [.]
  else
    [split("\n")[] | if units <= $limit then with_units else (hard_split[] | with_units) end]
    | pack("\n")
  end;

$text
| [split("\n\n")[] | fit_paragraph[] | with_units]
| pack("\n\n")
| map(select(test("\\S")))
| .[]
| . + "\u0000"
