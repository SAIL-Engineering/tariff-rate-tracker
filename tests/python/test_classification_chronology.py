import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('chronology', ROOT / 'scripts/audit_classification_chronology.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def test_explicit_statistical_dates_do_not_use_header_or_previous_row():
    text = '''February 9, 2026
0201.30.5085   Discontinued (transferred to 0201.30.5091 and   February 1, 2026   484(f)
               0201.30.5097)
0201.30.5091   Established (transferred from 0201.30.5085)    February 1, 2026   484(f)
0201.30.5097   Established
9903.01.99     Added                                       February 1, 2026   PP example
'''
    events, unresolved = m.parse_events(text, 'fixture', 'a' * 64)
    assert len(events) == 2 and len(unresolved) == 2
    assert events[0]['effective_date'] == '2026-02-01'
    assert events[0]['page'] == 1 and events[0]['line'] == 2
    assert events[0]['printed_source'] == '484(f)'
    before, _ = m.expectations(events, '2026-01-31')
    assert '0201305085' not in before
    assert not before['0201305091']['present']
    after, _ = m.expectations(events, '2026-02-01')
    assert not after['0201305085']['present'] and after['0201305091']['present']


def test_conflicts_are_not_resolved_by_order_or_a_maximum():
    events, _ = m.parse_events('''0901.11.0035 Established July 1, 2025 484(f)
0901.11.0035 Discontinued July 1, 2025 484(f)
''', 'fixture', 'a' * 64)
    for rows in (events, list(reversed(events))):
        expected, conflicts = m.expectations(rows, '2025-07-01')
        assert not expected and conflicts[0]['code'] == '0901110035'


def test_ten_digit_deleted_and_centered_code_cells_keep_their_own_dates():
    text = '''3818.00.0095 Deleted (transferred to other numbers) July 1, 2026 484(f)
                   Established (transferred from      July 1, 2026 484(f)
3004.90.9221       3004.90.9219)
0901.11.0040 Established
'''
    events, questions = m.parse_events(text, 'fixture', 'a' * 64)
    assert len(events) == 2 and len(questions) == 1
    assert not events[0]['present_after']
    assert events[1]['code'] == '3004909221' and events[1]['present_after']
    assert events[1]['effective_date'] == '2026-07-01'
    assert events[1]['extraction_layout'] == 'centered_first_column'
    assert events[1]['line'] == 3 and len(events[1]['raw_lines']) == 2
