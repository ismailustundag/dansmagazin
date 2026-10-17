import ast
from datetime import datetime
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('locations', ROOT / 'app/event_locations.py')
locations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(locations)


class LocationTests(unittest.TestCase):
    def test_worldwide_and_legacy_identity(self):
        rows = [dict(city=name, country_code=country, city_id=identity) for name, country, identity in [
            ('Ankara', 'TR', ''), ('Valencia', 'ES', 'geo:2509954'),
            ('Massanassa / Valencia', '', ''), ('Bangkok', 'TH', ''), ('Warsaw', 'PL', ''),
            ('Springfield', 'US', 'geo:1'), ('Springfield', 'US', 'geo:2'),
            ('València', 'ES', ''), ('Valencia', 'VE', ''),
        ]]
        result = locations.location_options(rows)
        self.assertEqual(len(result['cities']), 9)
        self.assertEqual(len({(r['country_code'], r['city_id']) for r in result['cities']}), 9)
        massanassa = next(r for r in result['cities'] if r['city'].startswith('Massanassa'))
        self.assertEqual(massanassa['country_code'], '')
        self.assertEqual(massanassa['city'], 'Massanassa / Valencia')

    def test_options_not_limited_and_refresh_discovers_new_city(self):
        rows = [dict(city=f'Place {i}', country_code='TR') for i in range(650)]
        self.assertEqual(len(locations.location_options(rows)['cities']), 650)
        rows.append(dict(city='Bangkok', country_code='TH'))
        self.assertEqual(len(locations.location_options(rows)['cities']), 651)

    def test_country_options_require_a_city(self):
        result = locations.location_options([
            dict(city='', country_code='US', city_id=''),
            dict(city='Ankara', country_code='TR', city_id=''),
        ])
        self.assertEqual([item['code'] for item in result['countries']], ['TR'])

    def test_combined_filters_keep_legacy_contract_and_use_parameters(self):
        wheres, values = locations.public_filters(city='Ankara', event_kind='festival', styles=['salsa', 'bachata'], country_code='TR', city_id='geo:1')
        self.assertEqual(values, ['ankara', 'TR', 'geo:1', 'festival', '%,salsa,%', '%,bachata,%'])
        self.assertIn("LOWER(COALESCE(mes.city,''))=%s", wheres)
        self.assertNotIn('geo:1', ' '.join(wheres))
        self.assertEqual(locations.public_filters(country_code='__unknown__')[1], [''])

    def test_invalid_identity_and_country_rejected(self):
        self.assertEqual(locations.validate_location(' es ', 'geo:1'), ('ES', 'geo:1'))
        for country, city in [('ZZ', ''), ('TR', "' OR 1=1"), ('TR', 'x'*129)]:
            with self.assertRaises(ValueError): locations.validate_location(country, city)

    def test_edit_preserves_identity_unless_location_changes(self):
        old = dict(city='Valencia', country_code='ES', city_id='geo:valencia')
        self.assertEqual(locations.edited_location(old, city='Valencia'), ('ES', 'geo:valencia'))
        country, identity = locations.edited_location(old, city='Massanassa', city_id='')
        self.assertEqual(country, 'ES')
        self.assertTrue(identity.startswith('manual:'))
        self.assertNotEqual(identity, 'geo:valencia')
        self.assertEqual(locations.edited_location(old, city='Valencia', country_code='VE', city_id='geo:venezuela'), ('VE', 'geo:venezuela'))

    def test_copy_and_weekly_rollover_preserve_location(self):
        tree = ast.parse((ROOT / 'app/routers/events.py').read_text())
        copy = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'copy_manage_item')
        call = next(n for n in ast.walk(copy) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == '_insert_mobile_event_submission')
        self.assertTrue({'country_code','city_id'}.issubset({k.arg for k in call.keywords}))
        rollover = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_rollover_and_expire_events')
        self.assertTrue(any(isinstance(n, ast.Constant) and isinstance(n.value,str) and 'SET country_code=%s, city_id=%s' in n.value for n in ast.walk(rollover)))

    def test_current_scope_excludes_past_and_invalid_dates(self):
        tree = ast.parse((ROOT / 'app/routers/events.py').read_text())
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == '_current_public_event_ids')
        class DB:
            def cursor(self): return self
            def execute(self, sql):
                self.sql = sql
            def fetchall(self):
                return [dict(id=i, end_at=end, event_date=start) for i, end, start in [
                    (1, '', '2026-10-12'), (2, '', '2026-10-10'), (3, '2026-10-12', '2026-10-09'), (4, '', '')]]
        def parse(value):
            return datetime.fromisoformat(value).date() if value else None
        ns = dict(_now_local=lambda: datetime(2026,10,11), _parse_event_date_text=parse)
        exec(compile(ast.Module(body=[node], type_ignores=[]), '<test>', 'exec'), ns)
        db = DB()
        self.assertEqual(ns['_current_public_event_ids'](db), [1,3])
        self.assertIn("mes.status='approved'", db.sql)
        self.assertIn('COALESCE(se.is_active,1)=1', db.sql)
        self.assertNotIn('LIMIT', db.sql)


if __name__ == '__main__': unittest.main()
