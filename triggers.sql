USE court_cms;

DELIMITER //

CREATE TRIGGER trg_hearing_clash_insert
BEFORE INSERT ON hearings
FOR EACH ROW
BEGIN
    IF EXISTS (
        SELECT 1 FROM hearings
        WHERE hearing_date = NEW.hearing_date
          AND status = 'Scheduled'
          AND (judge_id = NEW.judge_id OR courtroom_id = NEW.courtroom_id)
          AND NEW.start_time < end_time
          AND NEW.end_time   > start_time
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Clash: judge or courtroom already booked for this time slot';
    END IF;
END//