-- ICT371 Advanced Database - Question 8: Fleet Maintenance

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead
        CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles at different service positions (4000, 6000 and 0 km since service)
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001', 12000,  8000),
    ('ABC 1002', 20000, 14000),
    ('ABC 1003',  5000,  5000);

-- The six trips are added through pr_record_trip at the end of part (d),
-- after the trigger is installed.

-- ==== (b) Function: fn_service_due ====
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;                 -- at least 5,000 km since the last service
END;
$$ LANGUAGE plpgsql;

SELECT fn_service_due(1);                -- false (4000 km)
SELECT fn_service_due(2);                -- true  (6000 km)
-- SELECT fn_service_due(99);            -- error: unknown vehicle

-- ==== (c) Procedure: pr_record_trip ====
-- Does not touch the odometer; the trigger on trips does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)',
                        p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ==== (d) Trigger: check start odometer and update the vehicle once ====
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Lock the vehicle row so concurrent trips cannot use the same start value
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    -- A BEFORE INSERT row trigger fires once per new row: odometer moves once
    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- Seed: six trips through the procedure; each starts at the current odometer
CALL pr_record_trip(1, '2026-11-10', 12000, 12600);
CALL pr_record_trip(1, '2026-11-14', 12600, 13200);   -- vehicle 1 now 5200 km since service
CALL pr_record_trip(2, '2026-11-11', 20000, 20300);
CALL pr_record_trip(2, '2026-11-15', 20300, 20800);
CALL pr_record_trip(3, '2026-11-12',  5000,  5400);
CALL pr_record_trip(3, '2026-11-16',  5400,  5900);

SELECT * FROM trips ORDER BY trip_id;
SELECT vehicle_id, registration, current_odometer FROM vehicles ORDER BY vehicle_id;

-- Error tests
-- CALL pr_record_trip(1, CURRENT_DATE, 100, 200);     -- error: start <> current (13200)
-- CALL pr_record_trip(1, CURRENT_DATE, 13200, 13200); -- error: end not greater than start
-- CALL pr_record_trip(99, CURRENT_DATE, 0, 10);       -- error: unknown vehicle

-- ==== (e) View: v_service_due ====
CREATE OR REPLACE VIEW v_service_due AS
SELECT vehicle_id,
       registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;                           -- vehicles 1 and 2

-- ==== (f) Index ====
-- Justification: the search is "one vehicle's trips in a date range". Equality
-- on vehicle_id first and the range on trip_on second lets the B-tree jump to
-- that vehicle's entries and read the date range in order.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

-- ==== (g) Scheduled job: pr_refresh_service_alerts ====
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- Insert or update one alert per due vehicle
    -- (flagged_on keeps the date the vehicle was first flagged)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

    -- Remove alerts for vehicles that are no longer due
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- vehicles 1 and 2

-- Vehicle 2 is serviced: its alert is removed on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- vehicle 1 only

-- Schedule every Monday at 06:00 (pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_service_alerts_weekly',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts()$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;
