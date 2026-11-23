
USE court_cms;

DROP PROCEDURE IF EXISTS sp_add_case;
DROP PROCEDURE IF EXISTS sp_add_party_to_case;
DROP PROCEDURE IF EXISTS sp_schedule_hearing;
DROP PROCEDURE IF EXISTS sp_record_outcome;
DROP PROCEDURE IF EXISTS sp_update_case_status;
DROP PROCEDURE IF EXISTS sp_add_document;
DROP PROCEDURE IF EXISTS sp_assign_advocate;

DELIMITER //

-- =====================================================
-- OPTION 1 : REGISTER A CASE  (Admin, Clerk)
-- =====================================================
CREATE PROCEDURE sp_add_case(
    IN p_case_number VARCHAR(30), IN p_title VARCHAR(200), IN p_case_type_id INT,
    IN p_description TEXT, IN p_filing_date DATE, IN p_priority VARCHAR(10),
    IN p_judge_id INT)
BEGIN
    DECLARE v_id INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(1);

    START TRANSACTION;
    INSERT INTO cases (case_number, title, case_type_id, description, filing_date,
                       status, priority, judge_id, created_by)
    VALUES (p_case_number, p_title, p_case_type_id, p_description, p_filing_date,
            'Filed', IFNULL(p_priority, 'Normal'), p_judge_id, fn_cur_user());
    SET v_id = LAST_INSERT_ID();

    INSERT INTO case_status_history (case_id, old_status, new_status, changed_by, remarks)
    VALUES (v_id, NULL, 'Filed', fn_cur_user(), 'Case registered');
    COMMIT;

    SELECT CONCAT('Case ', p_case_number, ' registered. case_id = ', v_id) AS Result;
END//

-- =====================================================
-- OPTION 2 : ADD PARTY TO CASE  (Admin, Clerk)
-- p_user_id links the party to a Client login so that client can see the case
-- =====================================================
CREATE PROCEDURE sp_add_party_to_case(
    IN p_case_id INT, IN p_party_name VARCHAR(100), IN p_address VARCHAR(255),
    IN p_phone VARCHAR(15), IN p_role VARCHAR(20), IN p_user_id INT)
BEGIN
    DECLARE v_party_id INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(2);
    CALL sp_require_case(p_case_id);

    IF p_user_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM users u JOIN roles r ON r.role_id = u.role_id
        WHERE u.user_id = p_user_id AND r.role_name = 'Client') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The linked user must be an existing Client account.';
    END IF;

    START TRANSACTION;
    INSERT INTO parties (user_id, party_name, address, phone)
    VALUES (p_user_id, p_party_name, p_address, p_phone);
    SET v_party_id = LAST_INSERT_ID();
    INSERT INTO case_parties (case_id, party_id, party_role) VALUES (p_case_id, v_party_id, p_role);
    COMMIT;

    CALL sp_log('INSERT', 'case_parties', p_case_id, CONCAT('Party added: ', p_party_name, ' as ', p_role));
    SELECT CONCAT(p_party_name, ' added to case ', p_case_id, ' as ', p_role,
                  ' (party_id = ', v_party_id, ')') AS Result;
END//

-- =====================================================
-- OPTION 25 : ASSIGN ADVOCATE TO A PARTY  (Admin, Clerk)
-- =====================================================
CREATE PROCEDURE sp_assign_advocate(IN p_case_id INT, IN p_advocate_id INT, IN p_party_id INT)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(25);
    CALL sp_require_case(p_case_id);

    IF NOT EXISTS (SELECT 1 FROM case_parties WHERE case_id = p_case_id AND party_id = p_party_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That party is not part of this case.';
    END IF;

    INSERT INTO case_advocates (case_id, advocate_id, party_id)
    VALUES (p_case_id, p_advocate_id, p_party_id);

    CALL sp_log('INSERT', 'case_advocates', p_case_id,
                CONCAT('Advocate ', p_advocate_id, ' assigned to party ', p_party_id));
    SELECT 'Advocate assigned.' AS Result;
END//

-- =====================================================
-- OPTION 3 : SCHEDULE A HEARING  (Admin, Clerk)
-- =====================================================
CREATE PROCEDURE sp_schedule_hearing(
    IN p_case_id INT, IN p_judge_id INT, IN p_courtroom_id INT,
    IN p_date DATE, IN p_start TIME, IN p_end TIME, IN p_purpose VARCHAR(100))
BEGIN
    DECLARE v_status VARCHAR(30);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(3);
    CALL sp_require_case(p_case_id);

    SELECT status INTO v_status FROM cases WHERE case_id = p_case_id;

    IF v_status = 'Disposed' THEN
        SELECT 'ERROR: Case is already disposed. Cannot schedule a hearing.' AS Result;
    ELSEIF p_date < CURDATE() THEN
        SELECT 'ERROR: Hearing date cannot be in the past.' AS Result;
    ELSE
        -- trigger trg_hearing_clash_insert rejects judge/room clashes
        INSERT INTO hearings (case_id, judge_id, courtroom_id, hearing_date,
                              start_time, end_time, purpose)
        VALUES (p_case_id, p_judge_id, p_courtroom_id, p_date, p_start, p_end, p_purpose);

        SELECT CONCAT('Hearing scheduled. hearing_id = ', LAST_INSERT_ID()) AS Result;
    END IF;
END//

-- =====================================================
-- OPTION 4 : RECORD HEARING OUTCOME  (Admin, Clerk, Judge of that case)
-- =====================================================
CREATE PROCEDURE sp_record_outcome(
    IN p_hearing_id INT, IN p_status VARCHAR(20), IN p_notes TEXT,
    IN p_reason VARCHAR(255), IN p_next_date DATE)
BEGIN
    DECLARE v_case_id INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(4);

    SELECT case_id INTO v_case_id FROM hearings WHERE hearing_id = p_hearing_id;
    IF v_case_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Hearing not found.';
    END IF;
    CALL sp_require_case(v_case_id);

    START TRANSACTION;
    UPDATE hearings
    SET status = p_status, outcome_notes = p_notes,
        adjournment_reason = p_reason, next_hearing_date = p_next_date
    WHERE hearing_id = p_hearing_id;

    -- keep the case status in step with the hearing result
    IF p_status = 'Adjourned' THEN
        UPDATE cases SET status = 'Adjourned' WHERE case_id = v_case_id;
    ELSEIF p_status = 'Completed' THEN
        UPDATE cases SET status = 'Under Hearing'
        WHERE case_id = v_case_id AND status IN ('Filed', 'Adjourned');
    END IF;
    COMMIT;

    CALL sp_log('UPDATE', 'hearings', p_hearing_id, CONCAT('Outcome recorded: ', p_status));
    SELECT CONCAT('Hearing ', p_hearing_id, ' marked ', p_status,
                  IF(p_next_date IS NOT NULL, CONCAT('. Next date: ', p_next_date), '')) AS Result;
END//

-- =====================================================
-- OPTION 5 : UPDATE CASE STATUS  (Admin, Clerk, Judge of that case)
-- Only a Judge or Admin may set 'Judgment Reserved' or 'Disposed'.
-- =====================================================
CREATE PROCEDURE sp_update_case_status(
    IN p_case_id INT, IN p_new_status VARCHAR(30), IN p_remarks VARCHAR(255))
BEGIN
    DECLARE v_hist_id INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(5);
    CALL sp_require_case(p_case_id);

    IF fn_cur_role() = 'Clerk' AND p_new_status IN ('Judgment Reserved', 'Disposed') THEN
        CALL sp_log('ACCESS_DENIED', 'cases', p_case_id, CONCAT('Clerk tried to set ', p_new_status));
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Only a Judge or Admin can reserve judgment or dispose a case.';
    END IF;

    START TRANSACTION;
    UPDATE cases
    SET status = p_new_status,
        disposed_date = IF(p_new_status = 'Disposed', CURDATE(), disposed_date)
    WHERE case_id = p_case_id;

    -- the trigger logged the change; attach the remarks to that history row
    SELECT MAX(history_id) INTO v_hist_id FROM case_status_history WHERE case_id = p_case_id;
    UPDATE case_status_history SET remarks = p_remarks WHERE history_id = v_hist_id;
    COMMIT;

    SELECT CONCAT('Case ', p_case_id, ' status is now ', p_new_status) AS Result;
END//

-- =====================================================
-- OPTION 6 : ADD DOCUMENT  (Admin, Clerk, Lawyer of that case)
-- =====================================================
CREATE PROCEDURE sp_add_document(
    IN p_case_id INT, IN p_doc_type VARCHAR(20), IN p_file_name VARCHAR(255),
    IN p_file_path VARCHAR(500))
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(6);
    CALL sp_require_case(p_case_id);

    INSERT INTO documents (case_id, doc_type, file_name, file_path, uploaded_by)
    VALUES (p_case_id, p_doc_type, p_file_name, p_file_path, fn_cur_user());

    SELECT CONCAT('Document saved. document_id = ', LAST_INSERT_ID()) AS Result;
END//

DELIMITER ;

-- >>>>>>>>>> 08_reports.sql <<<<<<<<<<
-- =====================================================
-- PART 08 : REPORT AND VIEW PROCEDURES  (menu options 7-18)
--
-- WHAT THIS FILE DOES (plain English):
--   Procedures that only READ information (SELECT) - cause list, search,
--   case details, timeline, reports, notifications.
--
-- TWO SAFETY CHECKS IN EACH ONE:
--   CALL sp_require(n)          -> is this role allowed to use the option?
--   fn_can_view_case(case_id)   -> is this person connected with the case?
--                                  Rows they may not see are left out.
--
-- WORDS YOU WILL SEE:
--   JOIN  = combine rows from two tables that are related
--   WHERE = keep only the rows that match a condition
--   ORDER BY = sort the result
-- =====================================================
USE court_cms;

DROP PROCEDURE IF EXISTS sp_cause_list;
DROP PROCEDURE IF EXISTS sp_upcoming_hearings;
DROP PROCEDURE IF EXISTS sp_search_case;
DROP PROCEDURE IF EXISTS sp_case_details;
DROP PROCEDURE IF EXISTS sp_case_timeline;
DROP PROCEDURE IF EXISTS sp_pending_vs_disposed;
DROP PROCEDURE IF EXISTS sp_cases_by_type;
DROP PROCEDURE IF EXISTS sp_judge_workload;
DROP PROCEDURE IF EXISTS sp_cases_without_hearing;
DROP PROCEDURE IF EXISTS sp_status_history;
DROP PROCEDURE IF EXISTS sp_generate_reminders;
DROP PROCEDURE IF EXISTS sp_view_notifications;

DELIMITER //

-- OPTION 7 : CAUSE LIST
CREATE PROCEDURE sp_cause_list(IN p_date DATE)
BEGIN
    CALL sp_require(7);
    SELECT r.room_number AS Room, h.start_time AS Start, h.end_time AS End,
           c.case_number AS CaseNo, c.title AS Title, h.purpose AS Purpose,
           u.full_name AS Judge
    FROM hearings h
    JOIN cases c      ON c.case_id = h.case_id
    JOIN judges j     ON j.judge_id = h.judge_id
    JOIN users u      ON u.user_id = j.user_id
    JOIN courtrooms r ON r.courtroom_id = h.courtroom_id
    WHERE h.hearing_date = p_date AND h.status = 'Scheduled'
      AND fn_can_view_case(h.case_id)
    ORDER BY r.room_number, h.start_time;
END//

-- OPTION 8 : UPCOMING HEARINGS
CREATE PROCEDURE sp_upcoming_hearings(IN p_days INT)
BEGIN
    CALL sp_require(8);
    SELECT h.hearing_id AS HearingID, c.case_number AS CaseNo, c.title AS Title,
           h.hearing_date AS Date, h.start_time AS Start, h.purpose AS Purpose
    FROM hearings h JOIN cases c ON c.case_id = h.case_id
    WHERE h.status = 'Scheduled'
      AND h.hearing_date BETWEEN CURDATE() AND DATE_ADD(CURDATE(), INTERVAL p_days DAY)
      AND fn_can_view_case(h.case_id)
    ORDER BY h.hearing_date, h.start_time;
END//

-- OPTION 9 : SEARCH
CREATE PROCEDURE sp_search_case(IN p_text VARCHAR(100))
BEGIN
    CALL sp_require(9);
    SELECT DISTINCT c.case_id AS CaseID, c.case_number AS CaseNo, c.title AS Title,
           c.status AS Status, c.filing_date AS Filed
    FROM cases c
    LEFT JOIN case_parties cp ON cp.case_id = c.case_id
    LEFT JOIN parties p       ON p.party_id = cp.party_id
    WHERE (c.case_number LIKE CONCAT('%', p_text, '%')
        OR c.title       LIKE CONCAT('%', p_text, '%')
        OR p.party_name  LIKE CONCAT('%', p_text, '%'))
      AND fn_can_view_case(c.case_id)
    ORDER BY Filed DESC;
END//

-- OPTION 10 : CASE DETAILS
CREATE PROCEDURE sp_case_details(IN p_case_id INT)
BEGIN
    CALL sp_require(10);
    CALL sp_require_case(p_case_id);

    SELECT c.case_number AS CaseNo, c.title AS Title, ct.type_name AS Type,
           c.status AS Status, c.priority AS Priority, c.filing_date AS Filed,
           u.full_name AS Judge, c.description AS Description
    FROM cases c
    JOIN case_types ct ON ct.case_type_id = c.case_type_id
    LEFT JOIN judges j ON j.judge_id = c.judge_id
    LEFT JOIN users u  ON u.user_id = j.user_id
    WHERE c.case_id = p_case_id;

    SELECT p.party_name AS Party, cp.party_role AS Role, au.full_name AS Advocate
    FROM case_parties cp
    JOIN parties p ON p.party_id = cp.party_id
    LEFT JOIN case_advocates ca ON ca.case_id = cp.case_id AND ca.party_id = cp.party_id
    LEFT JOIN advocates a       ON a.advocate_id = ca.advocate_id
    LEFT JOIN users au          ON au.user_id = a.user_id
    WHERE cp.case_id = p_case_id;

    SELECT doc_type AS DocType, file_name AS FileName, uploaded_at AS Uploaded
    FROM documents WHERE case_id = p_case_id;
END//

-- OPTION 11 : TIMELINE
CREATE PROCEDURE sp_case_timeline(IN p_case_id INT)
BEGIN
    CALL sp_require(11);
    CALL sp_require_case(p_case_id);
    SELECT hearing_id AS HearingID, hearing_date AS Date, purpose AS Purpose,
           status AS Status, outcome_notes AS Outcome,
           adjournment_reason AS AdjournedBecause, next_hearing_date AS NextDate
    FROM hearings WHERE case_id = p_case_id ORDER BY hearing_date, start_time;
END//

-- OPTION 12 : PENDING VS DISPOSED  (a Judge sees only their own cases)
CREATE PROCEDURE sp_pending_vs_disposed()
BEGIN
    CALL sp_require(12);
    SELECT CASE WHEN status = 'Disposed' THEN 'Disposed' ELSE 'Pending' END AS Category,
           COUNT(*) AS Total
    FROM cases
    WHERE fn_can_view_case(case_id)
    GROUP BY Category;
END//

-- OPTION 13 : CASES BY TYPE
CREATE PROCEDURE sp_cases_by_type()
BEGIN
    CALL sp_require(13);
    SELECT ct.type_name AS CaseType, COUNT(c.case_id) AS Total
    FROM case_types ct
    LEFT JOIN cases c ON c.case_type_id = ct.case_type_id AND fn_can_view_case(c.case_id)
    GROUP BY ct.type_name ORDER BY Total DESC;
END//

-- OPTION 14 : JUDGE WORKLOAD (Admin only)
CREATE PROCEDURE sp_judge_workload()
BEGIN
    CALL sp_require(14);
    SELECT u.full_name AS Judge, COUNT(c.case_id) AS PendingCases
    FROM judges j
    JOIN users u ON u.user_id = j.user_id
    LEFT JOIN cases c ON c.judge_id = j.judge_id AND c.status <> 'Disposed'
    GROUP BY u.full_name ORDER BY PendingCases DESC;
END//

-- OPTION 15 : CASES WITH NO FUTURE HEARING
CREATE PROCEDURE sp_cases_without_hearing()
BEGIN
    CALL sp_require(15);
    SELECT c.case_id AS CaseID, c.case_number AS CaseNo, c.title AS Title,
           c.status AS Status, c.priority AS Priority
    FROM cases c
    WHERE c.status <> 'Disposed'
      AND fn_can_view_case(c.case_id)
      AND NOT EXISTS (SELECT 1 FROM hearings h
                      WHERE h.case_id = c.case_id
                        AND h.hearing_date >= CURDATE() AND h.status = 'Scheduled')
    ORDER BY FIELD(c.priority, 'Urgent', 'High', 'Normal', 'Low');
END//

-- OPTION 16 : STATUS HISTORY (now shows who changed it)
CREATE PROCEDURE sp_status_history(IN p_case_id INT)
BEGIN
    CALL sp_require(16);
    CALL sp_require_case(p_case_id);
    SELECT h.changed_at AS ChangedAt, h.old_status AS OldStatus, h.new_status AS NewStatus,
           u.full_name AS ChangedBy, h.remarks AS Remarks
    FROM case_status_history h
    LEFT JOIN users u ON u.user_id = h.changed_by
    WHERE h.case_id = p_case_id ORDER BY h.changed_at, h.history_id;
END//

-- OPTION 17 : GENERATE REMINDERS FOR TOMORROW'S HEARINGS
CREATE PROCEDURE sp_generate_reminders()
BEGIN
    DECLARE v_count INT DEFAULT 0;
    CALL sp_require(17);

    INSERT INTO notifications (user_id, hearing_id, message)
    SELECT t.user_id, h.hearing_id,
           CONCAT('Reminder: case ', c.case_number, ' is listed on ', h.hearing_date,
                  ' at ', h.start_time, ' in room ', r.room_number)
    FROM hearings h
    JOIN cases c      ON c.case_id = h.case_id
    JOIN courtrooms r ON r.courtroom_id = h.courtroom_id
    JOIN (
        SELECT h2.hearing_id, j.user_id
        FROM hearings h2 JOIN judges j ON j.judge_id = h2.judge_id
        UNION
        SELECT h2.hearing_id, p.user_id
        FROM hearings h2
        JOIN case_parties cp ON cp.case_id = h2.case_id
        JOIN parties p ON p.party_id = cp.party_id
        WHERE p.user_id IS NOT NULL
        UNION
        SELECT h2.hearing_id, a.user_id
        FROM hearings h2
        JOIN case_advocates ca ON ca.case_id = h2.case_id
        JOIN advocates a ON a.advocate_id = ca.advocate_id
    ) t ON t.hearing_id = h.hearing_id
    WHERE h.hearing_date = DATE_ADD(CURDATE(), INTERVAL 1 DAY)
      AND h.status = 'Scheduled'
      AND NOT EXISTS (SELECT 1 FROM notifications n
                      WHERE n.hearing_id = h.hearing_id AND n.user_id = t.user_id);

    SET v_count = ROW_COUNT();
    CALL sp_log('REMINDERS', 'notifications', NULL, CONCAT(v_count, ' reminders generated'));
    SELECT CONCAT(v_count, ' reminder(s) generated for hearings on ',
                  DATE_ADD(CURDATE(), INTERVAL 1 DAY)) AS Result;
END//

-- OPTION 18 : MY NOTIFICATIONS (only your own; marks them as read)
CREATE PROCEDURE sp_view_notifications()
BEGIN
    DECLARE v_user INT;
    CALL sp_require(18);
    SET v_user = fn_cur_user();

    SELECT notification_id AS ID, message AS Message,
           IF(is_read, 'Read', 'NEW') AS Status, created_at AS Received
    FROM notifications WHERE user_id = v_user ORDER BY created_at DESC;

    UPDATE notifications SET is_read = TRUE WHERE user_id = v_user AND is_read = FALSE;
END//

DELIMITER ;

-- >>>>>>>>>> 09_user_admin.sql <<<<<<<<<<
-- =====================================================
-- PART 09 : USER ACCOUNTS
--
-- WHAT THIS FILE DOES (plain English):
--   How accounts get created, like in a real court:
--     * Judges, lawyers and clerks are registered by an ADMIN, who gives
--       them a login id and a TEMPORARY password. They must change it
--       the first time they log in.                (sp_create_user)
--     * Clients register THEMSELVES, and can only ever become a Client.
--                                                (sp_register_client)
--     * An admin can reset a forgotten password.  (sp_reset_password)
--     * An admin can disable / unlock an account.  (sp_set_user_active)
--     * An admin can read the audit log and the user list.
-- =====================================================
USE court_cms;

DROP PROCEDURE IF EXISTS sp_create_user;
DROP PROCEDURE IF EXISTS sp_register_client;
DROP PROCEDURE IF EXISTS sp_reset_password;
DROP PROCEDURE IF EXISTS sp_set_user_active;
DROP PROCEDURE IF EXISTS sp_view_audit;
DROP PROCEDURE IF EXISTS sp_list_users;

DELIMITER //

-- =====================================================
-- OPTION 19 : ADMIN CREATES A STAFF ACCOUNT
--   CALL sp_create_user('Name','email','phone','Judge','Temp@1234','Designation','Court');
--   Judge  : p_extra1 = designation,    p_extra2 = court name
--   Lawyer : p_extra1 = bar council no, p_extra2 = specialization
--   Clerk / Admin : extras can be NULL
-- The new user must change the temporary password at first login.
-- =====================================================
CREATE PROCEDURE sp_create_user(
    IN p_name VARCHAR(100), IN p_email VARCHAR(100), IN p_phone VARCHAR(15),
    IN p_role_name VARCHAR(30), IN p_password VARCHAR(100),
    IN p_extra1 VARCHAR(100), IN p_extra2 VARCHAR(100))
BEGIN
    DECLARE v_role_id INT DEFAULT NULL;
    DECLARE v_user_id INT;
    DECLARE v_salt    CHAR(32);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(19);                                   -- Admin only

    -- Step 1: check the inputs
    SELECT role_id INTO v_role_id FROM roles WHERE role_name = p_role_name;
    IF v_role_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown role. Use Admin, Judge, Lawyer, Clerk or Client.';
    END IF;
    IF p_role_name = 'Client' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Clients register themselves with sp_register_client.';
    END IF;
    IF p_email NOT LIKE '%_@_%._%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That does not look like a valid email address.';
    END IF;
    IF CHAR_LENGTH(p_password) < 8 OR p_password NOT REGEXP '[0-9]' OR p_password NOT REGEXP '[A-Za-z]' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Password needs at least 8 characters with letters and digits.';
    END IF;
    IF p_role_name = 'Judge' AND (p_extra1 IS NULL OR p_extra2 IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Judge needs extra1 = designation and extra2 = court name.';
    END IF;
    IF p_role_name = 'Lawyer' AND p_extra1 IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lawyer needs extra1 = bar council number.';
    END IF;

    -- Step 2: make the scrambled password
    SET v_salt = REPLACE(UUID(), '-', '');

    -- Step 3: save the user (and the judge / lawyer details) as one unit
    START TRANSACTION;
    INSERT INTO users (role_id, full_name, email, phone, password_hash, password_salt, must_change_password)
    VALUES (v_role_id, p_name, p_email, p_phone,
            SHA2(CONCAT(v_salt, p_password), 256), v_salt, TRUE);   -- TRUE = must change at first login
    SET v_user_id = LAST_INSERT_ID();

    IF p_role_name = 'Judge' THEN
        INSERT INTO judges (user_id, designation, court_name) VALUES (v_user_id, p_extra1, p_extra2);
    ELSEIF p_role_name = 'Lawyer' THEN
        INSERT INTO advocates (user_id, bar_council_no, specialization) VALUES (v_user_id, p_extra1, p_extra2);
    END IF;
    COMMIT;

    CALL sp_log('CREATE_USER', 'users', v_user_id, CONCAT('Created ', p_role_name, ' account: ', p_email));
    SELECT CONCAT('User created. user_id = ', v_user_id, ' (', p_role_name,
                  '). They must change the temporary password at first login.') AS Result;
END//

-- =====================================================
-- CLIENT SELF-REGISTRATION  (works BEFORE login; no menu number)
--   CALL sp_register_client('Name', 'email', 'phone', 'MyPass123');
-- The role is fixed to Client inside this procedure, so nobody can
-- register themselves as an Admin or a Judge. A new client can see
-- nothing until a clerk links them to a case (see part 10).
-- =====================================================
CREATE PROCEDURE sp_register_client(
    IN p_name VARCHAR(100), IN p_email VARCHAR(100),
    IN p_phone VARCHAR(15), IN p_password VARCHAR(100))
BEGIN
    DECLARE v_role_id INT;
    DECLARE v_salt    CHAR(32);
    DECLARE v_user_id INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    IF fn_cur_user() IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You are logged in. Please logout before registering a new account.';
    END IF;
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Name is required.';
    END IF;
    IF p_email NOT LIKE '%_@_%._%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That does not look like a valid email address.';
    END IF;
    IF CHAR_LENGTH(p_password) < 8 OR p_password NOT REGEXP '[0-9]' OR p_password NOT REGEXP '[A-Za-z]' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Password needs at least 8 characters with letters and digits.';
    END IF;

    SELECT role_id INTO v_role_id FROM roles WHERE role_name = 'Client';   -- role is FIXED
    SET v_salt = REPLACE(UUID(), '-', '');

    START TRANSACTION;
    INSERT INTO users (role_id, full_name, email, phone, password_hash, password_salt, must_change_password)
    VALUES (v_role_id, TRIM(p_name), p_email, p_phone,
            SHA2(CONCAT(v_salt, p_password), 256), v_salt, FALSE);    -- they chose their own password
    SET v_user_id = LAST_INSERT_ID();
    COMMIT;

    CALL sp_log('REGISTER_CLIENT', 'users', v_user_id, CONCAT('Client registered: ', p_email));
    SELECT 'Registration successful. Login with sp_login, then ask to be linked to your case (option 26).' AS Result;
END//

-- =====================================================
-- OPTION 29 : ADMIN RESETS A FORGOTTEN PASSWORD
--   CALL sp_reset_password(user_id, 'Temp@1234');
-- The user must change it again at the next login.
-- =====================================================
CREATE PROCEDURE sp_reset_password(IN p_user_id INT, IN p_temp_password VARCHAR(100))
BEGIN
    DECLARE v_salt CHAR(32);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(29);

    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User not found.';
    END IF;
    IF CHAR_LENGTH(p_temp_password) < 8 OR p_temp_password NOT REGEXP '[0-9]' OR p_temp_password NOT REGEXP '[A-Za-z]' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Password needs at least 8 characters with letters and digits.';
    END IF;

    SET v_salt = REPLACE(UUID(), '-', '');
    UPDATE users
    SET password_salt = v_salt,
        password_hash = SHA2(CONCAT(v_salt, p_temp_password), 256),
        must_change_password = TRUE,
        failed_attempts = 0,
        locked_until = NULL
    WHERE user_id = p_user_id;

    DELETE FROM active_sessions WHERE user_id = p_user_id;      -- log them out everywhere

    CALL sp_log('RESET_PASSWORD', 'users', p_user_id, 'Password reset by admin');
    SELECT CONCAT('Password reset for user ', p_user_id, '. They must change it at next login.') AS Result;
END//

-- =====================================================
-- OPTION 20 : ACTIVATE / DEACTIVATE / UNLOCK A USER
--   CALL sp_set_user_active(user_id, 1);   -- 1 = active, 0 = disabled
-- =====================================================
CREATE PROCEDURE sp_set_user_active(IN p_user_id INT, IN p_active BOOLEAN)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(20);

    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_user_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User not found.';
    END IF;
    IF p_user_id = fn_cur_user() AND NOT p_active THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You cannot deactivate your own account.';
    END IF;

    UPDATE users SET is_active = p_active, failed_attempts = 0, locked_until = NULL
    WHERE user_id = p_user_id;

    IF NOT p_active THEN
        DELETE FROM active_sessions WHERE user_id = p_user_id;   -- kick them out now
    END IF;

    CALL sp_log('USER_STATUS', 'users', p_user_id, IF(p_active, 'Activated / unlocked', 'Deactivated'));
    SELECT CONCAT('User ', p_user_id, IF(p_active, ' is active (and unlocked).', ' is deactivated.')) AS Result;
END//

-- =====================================================
-- OPTION 21 : VIEW THE AUDIT LOG  (last N entries, newest first)
-- =====================================================
CREATE PROCEDURE sp_view_audit(IN p_limit INT)
BEGIN
    CALL sp_require(21);
    SELECT a.log_id AS ID, a.logged_at AS `When`, IFNULL(u.full_name, '(none)') AS Who,
           a.action AS Action, a.table_name AS TableName, a.record_id AS Record, a.details AS Details
    FROM audit_log a LEFT JOIN users u ON u.user_id = a.user_id
    ORDER BY a.log_id DESC
    LIMIT p_limit;
END//

-- =====================================================
-- OPTION 22 : LIST USERS  (never shows password data)
-- =====================================================
CREATE PROCEDURE sp_list_users()
BEGIN
    CALL sp_require(22);
    SELECT u.user_id AS ID, u.full_name AS Name, u.email AS Email, r.role_name AS Role,
           IF(u.is_active, 'Yes', 'No') AS Active,
           IF(u.must_change_password, 'Yes', '-') AS TempPassword,
           IF(u.locked_until IS NOT NULL AND u.locked_until > NOW(), 'LOCKED', '-') AS Locked,
           u.last_login AS LastLogin
    FROM users u JOIN roles r ON r.role_id = u.role_id
    ORDER BY u.user_id;
END//

DELIMITER ;

-- >>>>>>>>>> 10_client_link.sql <<<<<<<<<<
-- =====================================================
-- PART 10 : LINKING A CLIENT TO THEIR CASE
--
-- WHAT THIS FILE DOES (plain English):
--   A client who registered on their own cannot see any case yet. This is
--   how they get access, step by step:
--     1. The client says which case is theirs:   sp_request_case_link
--     2. A clerk sees the waiting requests:      sp_pending_requests
--     3. The clerk checks the person's identity (ID proof, in real life)
--        and approves or rejects:                sp_decide_link_request
--     4. On approval, the client's login is attached to the matching party
--        of that case, and from then on the client can see that case.
--
-- Why not link automatically? Otherwise a stranger could type any case
-- number and read someone else's private case.
-- =====================================================
USE court_cms;

DROP PROCEDURE IF EXISTS sp_request_case_link;
DROP PROCEDURE IF EXISTS sp_my_requests;
DROP PROCEDURE IF EXISTS sp_pending_requests;
DROP PROCEDURE IF EXISTS sp_decide_link_request;

DELIMITER //

-- =====================================================
-- OPTION 26 (Client) : ASK TO BE LINKED TO MY CASE
--   CALL sp_request_case_link('CIV/2026/0001', 'I am the plaintiff');
-- =====================================================
CREATE PROCEDURE sp_request_case_link(IN p_case_number VARCHAR(30), IN p_note VARCHAR(255))
BEGIN
    DECLARE v_case_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(26);

    SELECT case_id INTO v_case_id FROM cases WHERE case_number = p_case_number;

    -- Save the request only if the case exists, the client is not already
    -- linked to it, and there is no waiting request for it already.
    IF v_case_id IS NOT NULL
       AND NOT fn_can_view_case(v_case_id)
       AND NOT EXISTS (SELECT 1 FROM link_requests
                       WHERE user_id = fn_cur_user() AND case_id = v_case_id AND status = 'Pending') THEN
        INSERT INTO link_requests (user_id, case_id, note)
        VALUES (fn_cur_user(), v_case_id, p_note);
        CALL sp_log('LINK_REQUEST', 'link_requests', LAST_INSERT_ID(),
                    CONCAT('Client asked to be linked to case ', p_case_number));
    END IF;

    -- The same message is shown either way, so a stranger cannot use this
    -- procedure to find out which case numbers exist.
    SELECT 'Your request was sent. A clerk will verify your identity and link you if the details match.' AS Result;
END//

-- =====================================================
-- OPTION 30 (Client) : SEE MY OWN REQUESTS AND THEIR STATUS
-- =====================================================
CREATE PROCEDURE sp_my_requests()
BEGIN
    CALL sp_require(30);
    SELECT r.request_id AS RequestID, c.case_number AS CaseNo, r.status AS Status,
           r.requested_at AS Sent, r.reviewed_at AS Decided
    FROM link_requests r JOIN cases c ON c.case_id = r.case_id
    WHERE r.user_id = fn_cur_user()
    ORDER BY r.request_id DESC;
END//

-- =====================================================
-- OPTION 27 (Clerk, Admin) : SEE REQUESTS WAITING FOR A DECISION
-- First table: the requests.  Second table: the parties of those cases
-- that are not linked to a login yet - pick the matching party_id.
-- =====================================================
CREATE PROCEDURE sp_pending_requests()
BEGIN
    CALL sp_require(27);

    SELECT r.request_id AS RequestID, u.full_name AS ClientName, u.email AS Email,
           u.phone AS Phone, c.case_number AS CaseNo, c.title AS Title,
           r.note AS Note, r.requested_at AS Sent
    FROM link_requests r
    JOIN users u ON u.user_id = r.user_id
    JOIN cases c ON c.case_id = r.case_id
    WHERE r.status = 'Pending'
    ORDER BY r.requested_at;

    SELECT r.request_id AS RequestID, p.party_id AS PartyID,
           p.party_name AS PartyName, cp.party_role AS Role
    FROM link_requests r
    JOIN case_parties cp ON cp.case_id = r.case_id
    JOIN parties p       ON p.party_id = cp.party_id
    WHERE r.status = 'Pending' AND p.user_id IS NULL
    ORDER BY r.request_id, p.party_id;
END//

-- =====================================================
-- OPTION 28 (Clerk, Admin) : APPROVE OR REJECT A REQUEST
--   CALL sp_decide_link_request(1, 3, 'Approve');   -- link to party 3
--   CALL sp_decide_link_request(1, NULL, 'Reject');
-- =====================================================
CREATE PROCEDURE sp_decide_link_request(
    IN p_request_id INT, IN p_party_id INT, IN p_decision VARCHAR(10))
BEGIN
    DECLARE v_user_id INT DEFAULT NULL;
    DECLARE v_case_id INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        ROLLBACK;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(28);

    -- Step 1: find the waiting request
    SELECT user_id, case_id INTO v_user_id, v_case_id
    FROM link_requests WHERE request_id = p_request_id AND status = 'Pending';
    IF v_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No pending request with that id.';
    END IF;

    IF p_decision NOT IN ('Approve', 'Reject') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Decision must be Approve or Reject.';
    END IF;

    START TRANSACTION;

    IF p_decision = 'Approve' THEN
        -- Step 2: the chosen party must belong to that case and be unlinked
        IF p_party_id IS NULL OR NOT EXISTS (
               SELECT 1 FROM case_parties cp JOIN parties p ON p.party_id = cp.party_id
               WHERE cp.case_id = v_case_id AND p.party_id = p_party_id AND p.user_id IS NULL) THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Choose a party of this case that is not linked to a login yet.';
        END IF;

        -- Step 3: attach the client's login to the party
        UPDATE parties SET user_id = v_user_id WHERE party_id = p_party_id;
        UPDATE link_requests
        SET status = 'Approved', reviewed_by = fn_cur_user(), reviewed_at = NOW()
        WHERE request_id = p_request_id;
    ELSE
        UPDATE link_requests
        SET status = 'Rejected', reviewed_by = fn_cur_user(), reviewed_at = NOW()
        WHERE request_id = p_request_id;
    END IF;

    COMMIT;

    CALL sp_log('LINK_DECISION', 'link_requests', p_request_id,
                CONCAT(IF(p_decision = 'Approve', 'Approved', 'Rejected'), ' by staff', IF(p_decision = 'Approve', CONCAT(' (party ', p_party_id, ')'), '')));
    SELECT CONCAT('Request ', p_request_id, ' ', IF(p_decision = 'Approve', 'approved', 'rejected'), '.') AS Result;
END//

DELIMITER ;

-- >>>>>>>>>> 11_db_accounts.sql <<<<<<<<<<
-- =====================================================
-- PART 11 : THE MySQL ACCOUNT FOR NORMAL USERS  (second layer of safety)
--
-- WHAT THIS FILE DOES (plain English):
--   Creates a MySQL account called court_user. It is NOT allowed to read
--   or change any table directly. It may only CALL the procedures listed
--   below, and those procedures do the login and role checks.
--   (Procedures run with their creator's rights - MySQL's default - so
--    they can touch the tables on the user's behalf.)
--
-- Normal users connect like this:   mysql -u court_user -p court_cms
-- You (the person who sets up the database) use the root account.
--
-- Needs an account that can grant privileges (e.g. root) to run.
-- CHANGE THE PASSWORD BELOW before real use.
-- =====================================================
DROP USER IF EXISTS 'court_user'@'localhost';
CREATE USER 'court_user'@'localhost' IDENTIFIED BY 'Court#User2026';

-- login / logout / menu
GRANT EXECUTE ON PROCEDURE court_cms.sp_login               TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_logout              TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_main_menu           TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_menu                TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_change_password     TO 'court_user'@'localhost';
-- client self-registration (works before login)
GRANT EXECUTE ON PROCEDURE court_cms.sp_register_client     TO 'court_user'@'localhost';
-- client link requests
GRANT EXECUTE ON PROCEDURE court_cms.sp_request_case_link   TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_decide_link_request TO 'court_user'@'localhost';
-- data entry
GRANT EXECUTE ON PROCEDURE court_cms.sp_add_case            TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_add_party_to_case   TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_assign_advocate     TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_schedule_hearing    TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_record_outcome      TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_update_case_status  TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_add_document        TO 'court_user'@'localhost';
-- admin only (the procedure itself checks the role)
GRANT EXECUTE ON PROCEDURE court_cms.sp_create_user         TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_set_user_active     TO 'court_user'@'localhost';
GRANT EXECUTE ON PROCEDURE court_cms.sp_reset_password      TO 'court_user'@'localhost';
-- Not granted on purpose: sp_log, sp_require, sp_require_case, the report
-- procedures and the fn_* functions. They are reached only through the
-- procedures above (via sp_menu).
