BEGIN;
ALTER TABLE mobile_event_submissions ADD COLUMN IF NOT EXISTS country_code TEXT;
ALTER TABLE mobile_event_submissions ADD COLUMN IF NOT EXISTS city_id TEXT;
CREATE INDEX IF NOT EXISTS idx_event_location
    ON mobile_event_submissions(country_code, city_id) WHERE status='approved';
COMMIT;
