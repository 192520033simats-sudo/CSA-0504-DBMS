-- ============================================================================
-- MODULE 2: SLOT BOOKING & RESULT PROCESSING
-- Schema + Optimized Queries + Transaction/Concurrency Control
-- Run after 01_module1_archive.sql: mysql -u root -p certexam < 02_module2_booking_results.sql
-- ============================================================================

USE certexam;

-- ----------------------------------------------------------------------------
-- 1. Schema (3NF)
-- ----------------------------------------------------------------------------
CREATE TABLE center (
    center_id  INT PRIMARY KEY,
    name       VARCHAR(100) NOT NULL
);

CREATE TABLE exam_slot (
    slot_id       INT PRIMARY KEY,
    center_id     INT NOT NULL,
    exam_date     DATE NOT NULL,
    start_time    TIME NOT NULL,
    capacity      INT NOT NULL,
    booked_count  INT NOT NULL DEFAULT 0,
    FOREIGN KEY (center_id) REFERENCES center(center_id)
);
CREATE INDEX idx_slot_center_date ON exam_slot (center_id, exam_date);

CREATE TABLE booking (
    booking_id    BIGINT PRIMARY KEY AUTO_INCREMENT,
    candidate_id  BIGINT NOT NULL,
    slot_id       INT NOT NULL,
    status        ENUM('CONFIRMED','CANCELLED') NOT NULL,
    booked_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (candidate_id, slot_id),
    FOREIGN KEY (slot_id) REFERENCES exam_slot(slot_id)
);
CREATE INDEX idx_booking_status ON booking (status);

CREATE TABLE result (
    result_id     BIGINT PRIMARY KEY AUTO_INCREMENT,
    candidate_id  BIGINT NOT NULL,
    attempt_id    BIGINT NOT NULL,
    score         DECIMAL(6,2),
    published_by  VARCHAR(50),
    version       INT NOT NULL DEFAULT 0,
    published_at  DATETIME
);
CREATE UNIQUE INDEX idx_result_candidate ON result (candidate_id);

-- ----------------------------------------------------------------------------
-- 2. Sample data
-- ----------------------------------------------------------------------------
INSERT INTO center (center_id, name) VALUES
 (1,'Chennai Central Test Centre'), (2,'Coimbatore IT Park Centre'),
 (3,'Tiruppur Skill Centre'), (14,'Madurai Vocational Hub');

INSERT INTO exam_slot (slot_id, center_id, exam_date, start_time, capacity, booked_count) VALUES
 (501, 1, '2026-06-15', '09:00:00', 50, 49),   -- nearly full: good for the race-condition test
 (502, 1, '2026-06-15', '13:00:00', 50, 10),
 (503, 3, '2026-06-15', '09:00:00', 30, 30),   -- already full
 (504, 14,'2026-06-16', '09:00:00', 40, 5);

INSERT INTO result (candidate_id, attempt_id, score, published_by, version, published_at) VALUES
 (500012345, 99001, 65.0, 'EX101', 3, '2026-06-16 10:00:00');

-- ----------------------------------------------------------------------------
-- 3. Optimised queries — joins, subqueries, aggregates
-- ----------------------------------------------------------------------------

-- Bookings and average score per centre for a date (JOIN + GROUP BY + HAVING)
SELECT c.name AS center_name,
       COUNT(b.booking_id) AS total_bookings,
       AVG(r.score)        AS avg_score
  FROM center c
  JOIN exam_slot s ON s.center_id = c.center_id
  JOIN booking   b ON b.slot_id   = s.slot_id
  LEFT JOIN result r ON r.candidate_id = b.candidate_id
 WHERE s.exam_date = '2026-06-15'
 GROUP BY c.name
HAVING COUNT(b.booking_id) > 0;

-- Candidates booked but awaiting result — optimised as NOT EXISTS (see EXPLAIN below)
EXPLAIN ANALYZE
SELECT b.candidate_id
  FROM booking b
 WHERE b.status = 'CONFIRMED'
   AND NOT EXISTS (SELECT 1 FROM result r WHERE r.candidate_id = b.candidate_id);

-- Unoptimised equivalent, kept for the before/after comparison in Section 9
EXPLAIN ANALYZE
SELECT b.candidate_id
  FROM booking b
 WHERE b.status = 'CONFIRMED'
   AND b.candidate_id NOT IN (SELECT candidate_id FROM result);

-- ----------------------------------------------------------------------------
-- 4. Transaction 1 — Slot booking (pessimistic locking, prevents over-booking)
-- Call as a stored procedure so it can be invoked identically from two
-- concurrent sessions for the concurrency test.
-- ----------------------------------------------------------------------------
DELIMITER //
CREATE PROCEDURE book_slot(IN p_candidate_id BIGINT, IN p_slot_id INT, OUT p_status VARCHAR(40))
BEGIN
    DECLARE v_capacity INT;
    DECLARE v_booked   INT;

    START TRANSACTION;

    SELECT capacity, booked_count INTO v_capacity, v_booked
      FROM exam_slot
     WHERE slot_id = p_slot_id
       FOR UPDATE;                         -- row lock: blocks concurrent bookers

    IF v_booked < v_capacity THEN
        UPDATE exam_slot SET booked_count = booked_count + 1 WHERE slot_id = p_slot_id;
        INSERT INTO booking (candidate_id, slot_id, status)
        VALUES (p_candidate_id, p_slot_id, 'CONFIRMED');
        SAVEPOINT after_booking;
        COMMIT;
        SET p_status = 'Booking Confirmed';
    ELSE
        ROLLBACK;
        SET p_status = 'Slot Full - Booking Rejected';
    END IF;
END //
DELIMITER ;

-- ----------------------------------------------------------------------------
-- 5. Transaction 2 — Result publishing (optimistic concurrency via version col)
-- ----------------------------------------------------------------------------
DELIMITER //
CREATE PROCEDURE publish_result(IN p_candidate_id BIGINT, IN p_new_score DECIMAL(6,2),
                                 IN p_examiner VARCHAR(50), IN p_expected_version INT,
                                 OUT p_status VARCHAR(40))
BEGIN
    DECLARE v_rows INT;

    START TRANSACTION;

    UPDATE result
       SET score = p_new_score,
           version = version + 1,
           published_by = p_examiner,
           published_at = NOW()
     WHERE candidate_id = p_candidate_id
       AND version = p_expected_version;

    SET v_rows = ROW_COUNT();

    IF v_rows = 0 THEN
        ROLLBACK;
        SET p_status = 'Conflict - Retry (result was modified by another examiner)';
    ELSE
        COMMIT;
        SET p_status = 'Result Published';
    END IF;
END //
DELIMITER ;

-- ----------------------------------------------------------------------------
-- 6. Manual demonstration (single session) — run these to see it work
-- ----------------------------------------------------------------------------
-- Book a seat in the nearly-full slot 501 (49/50 booked -> should succeed once)
CALL book_slot(500099999, 501, @status); SELECT @status;

-- Try to book the already-full slot 503 -> should be rejected
CALL book_slot(500099998, 503, @status); SELECT @status;

-- Publish a result with the correct current version (3) -> should succeed
CALL publish_result(500012345, 78.5, 'EX102', 3, @status); SELECT @status;

-- Retry with the now-stale version (3 again) -> should report a conflict
CALL publish_result(500012345, 80.0, 'EX103', 3, @status); SELECT @status;

-- ----------------------------------------------------------------------------
-- 7. Access control (GRANT/REVOKE)
-- ----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS examiner_role, auditor_role;
GRANT SELECT, UPDATE ON certexam.result TO examiner_role;
GRANT SELECT ON certexam.exam_attempt TO auditor_role;
REVOKE DELETE ON certexam.exam_attempt FROM auditor_role;

-- ----------------------------------------------------------------------------
-- 8. Isolation level used for the booking transaction (set per-session)
-- ----------------------------------------------------------------------------
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
