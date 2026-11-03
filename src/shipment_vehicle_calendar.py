"""Calendar-year vehicle age, distinct from an Eastern tariff commencement.

The source supplies the number of years. Near NewYear a CBP entry-record year
is required only where it can change the result; no port timezone is invented.
"""
from datetime import datetime
from zoneinfo import ZoneInfo
from section232_note16_rules import val,op,both,either


def boundaries(start,until):
    out=[]
    for year in range(datetime.fromisoformat(start).year+1,datetime.fromisoformat(until).year+1):
        out.extend(datetime(y,m,d,tzinfo=ZoneInfo('America/New_York')).isoformat()
            for y,m,d in [(year-1,12,31),(year,1,1),(year,1,2)])
    return sorted({at for at in out if start<=at<=until})


def vintage(manufacture,entry_record_year,at,age_years,invalid_question):
    calendar=datetime.fromisoformat(at)
    if (calendar.month,calendar.day) in ((12,31),(1,1)):
        lo=calendar.year if calendar.month==12 else calendar.year-1;hi=lo+1
        needs_record=either(both(op('gt',manufacture,val(lo-age_years)),op('lte',manufacture,val(hi-age_years))),op('gt',manufacture,val(lo)))
        year=op('if',needs_record,entry_record_year,val(lo))
    else:year=val(calendar.year)
    return op('if',op('lte',manufacture,year),op('lte',manufacture,op('subtract',year,val(age_years))),{'unresolved_source':invalid_question})
