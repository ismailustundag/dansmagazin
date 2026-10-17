// Run with PGLITE_MODULE pointing to an isolated @electric-sql/pglite install.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const backend = fileURLToPath(new URL('../', import.meta.url));
const db = new PGlite();
await db.exec(`CREATE TABLE mobile_event_submissions(id serial primary key, city text, status text, approved_event_slug text, event_kind text, dance_styles text);
CREATE TABLE saas_events(slug text, is_active integer);`);
const migration = `ALTER TABLE mobile_event_submissions ADD COLUMN IF NOT EXISTS country_code TEXT;
ALTER TABLE mobile_event_submissions ADD COLUMN IF NOT EXISTS city_id TEXT;
CREATE INDEX IF NOT EXISTS idx_event_location ON mobile_event_submissions(country_code, city_id) WHERE status='approved';`;
await db.exec(migration); await db.exec(migration);
await db.exec(`INSERT INTO mobile_event_submissions(city,status,event_kind,dance_styles,country_code) SELECT 'Place '||i,'approved','festival','salsa','TR' FROM generate_series(1,650) i;
INSERT INTO mobile_event_submissions(city,status,event_kind,dance_styles,country_code,city_id) VALUES
('Valencia','approved','festival','salsa,bachata','ES','geo:valencia'),
('Valencia','approved','festival','salsa','VE','geo:valencia'),
('Massanassa / Valencia','approved','dance_night','tango',NULL,NULL),
('Warsaw','pending','festival','salsa','PL',NULL),
('Bangkok','expired','festival','salsa','TH',NULL),
('İstanbul','approved','dance_night','salsa',NULL,NULL);`);
function where(args) {
  const result = JSON.parse(execFileSync('python3', ['-c', 'import json,sys; from app.event_locations import public_filters; print(json.dumps(public_filters(**json.loads(sys.argv[1]))))', JSON.stringify(args)], { cwd: backend, encoding: 'utf8' }));
  let index = 0;
  return { sql: result[0].join(' AND ').replaceAll('%s', () => '$' + ++index), values: result[1] };
}
async function query(args) {
  const filter = where(args);
  return (await db.query('SELECT mes.* FROM mobile_event_submissions mes LEFT JOIN saas_events se ON se.slug=mes.approved_event_slug WHERE ' + filter.sql, filter.values)).rows;
}
assert.equal((await query({})).length,654);
assert.equal((await query({country_code:'ES',city_id:'geo:valencia',event_kind:'festival',styles:['bachata']})).length,1);
assert.equal((await query({country_code:'ES',city_id:'geo:valencia',event_kind:'dance_night'})).length,0);
assert.equal((await query({city:'Valencia'})).length,2);
const identity = execFileSync('python3',['-c','from app.event_locations import location_fields; print(location_fields({"city":"İstanbul"})["city_id"])'],{cwd:backend,encoding:'utf8'}).trim();
assert.equal((await query({city_id:identity,country_code:'__unknown__'}))[0].city,'İstanbul');
assert.equal((await query({country_code:'__unknown__'})).length,2);
await db.exec("INSERT INTO mobile_event_submissions(city,status,country_code) VALUES ('Bangkok','approved','TH')");
assert.equal((await query({country_code:'TH'})).length,1);
await db.exec("INSERT INTO saas_events VALUES ('hidden',0); UPDATE mobile_event_submissions SET approved_event_slug='hidden' WHERE city='Bangkok'");
assert.equal((await query({country_code:'TH'})).length,0);
await db.close();
console.log('PostgreSQL: migration rerun, 650+ cities, compound filters, Unicode legacy identity, publication refresh, active/status checks passed');
