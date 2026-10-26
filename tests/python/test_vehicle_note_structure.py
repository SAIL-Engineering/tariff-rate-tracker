"""Native note extraction must retain legal conditions across page layouts."""
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src'))
from section232_stacking import note, reporting_codes


@pytest.mark.parametrize('revision,number,last', [
    ('2025_rev_7',33,'e'), ('2025_rev_11',33,'h'),
    ('2025_rev_17',33,'j'), ('2026_rev_19',33,'u'),
    ('2026_rev_19',38,'l'), ('2026_rev_1',39,'d'),
])
def test_wrapped_references_and_nested_romans_do_not_select_outer_clauses(revision,number,last):
    raw = subprocess.check_output(['pdftotext','-layout',str(ROOT/f'data/us_notes/chapter99_{revision}.pdf'),'-'],text=True)
    clauses = note(raw,number)
    assert list(clauses) == [chr(i) for i in range(ord('a'),ord(last)+1)]
    if number==33:
        assert '8703.23.01' in clauses['b']
        assert 'manufactured in a year at least 25 years' in clauses['e']
        assert 'U.S. content' in clauses['c']
        if 'h' in clauses:
            assert 'that are not parts of passenger vehicles' in clauses['h']
            assert '8471' in clauses['g']
            assert '8471' not in clauses['a']
        assert '9903.96.01' not in clauses[last]  # The following aircraft note.
    if number==39:
        assert 'semiconductor articles for research and development' in clauses['d']


def test_structural_gaps_are_not_silently_absorbed():
    raw='SUBCHAPTER III\n33. (a) First rule.\n(b)   Second rule.\n(d)   Unexpected missing subdivision.\n34. (a) Next note.'
    with pytest.raises(ValueError,match='subdivision'):
        note(raw,33)


def test_uppercase_nested_romans_and_single_space_wrapped_reference():
    raw=('33. (a) Base rule referring to subdivision\n(b) of this note.\n'
         '(b)    Scope rule:\n    (i)    First inner condition.\n    (ii)   Second condition.\n'
         '(c)    Next outer rule.\n34. (a) Next note.')
    clauses=note(raw,33)
    assert list(clauses)==list('abc')
    assert '(b) of this note.' in clauses['a']
    assert '(i) First inner condition.' in clauses['b']
    assert '(ii) Second condition.' in clauses['b']


def test_reporting_ranges_keep_sentence_final_headings():
    assert reporting_codes('Articles under 9903.82.02 and 9903.82.04–9903.82.06. Wood under 9903.76.24.') == [
        '9903.76.24','9903.82.02','9903.82.04','9903.82.05','9903.82.06']
    with pytest.raises(ValueError,match='range'):
        reporting_codes('9903.82.26–9903.82.04')
