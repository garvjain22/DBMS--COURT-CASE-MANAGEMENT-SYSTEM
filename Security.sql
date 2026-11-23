
USE court_cms;

DROP FUNCTION  IF EXISTS fn_cur_user;
DROP FUNCTION  IF EXISTS fn_cur_role_id;
DROP FUNCTION  IF EXISTS fn_cur_role;
DROP FUNCTION  IF EXISTS fn_can_view_case;
DROP PROCEDURE IF EXISTS sp_log;
DROP PROCEDURE IF EXISTS sp_require;
DROP PROCEDURE IF EXISTS sp_require_case;
DROP PROCEDURE IF EXISTS sp_login;
DROP PROCEDURE IF EXISTS sp_logout;
DROP PROCEDURE IF EXISTS sp_change_password;

DELIMITER //


CREATE FUNCTION fn_cur_user() RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v INT DEFAULT NULL;
    SELECT user_id INTO v FROM active_sessions
    WHERE connection_id = CONNECTION_ID()
      AND last_activity > (NOW() - INTERVAL 30 MINUTE);
    RETURN v;
END//


CREATE FUNCTION fn_cur_role_id() RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v INT DEFAULT NULL;
    SELECT role_id INTO v FROM active_sessions
    WHERE connection_id = CONNECTION_ID()
      AND last_activity > (NOW() - INTERVAL 30 MINUTE);
    RETURN v;
END//


CREATE FUNCTION fn_cur_role() RETURNS VARCHAR(30)
READS SQL DATA
BEGIN
    DECLARE v VARCHAR(30) DEFAULT NULL;
    SELECT r.role_name INTO v
    FROM active_sessions s JOIN roles r ON r.role_id = s.role_id
    WHERE s.connection_id = CONNECTION_ID()
      AND s.last_activity > (NOW() - INTERVAL 30 MINUTE);
    RETURN v;
END//


CREATE FUNCTION fn_can_view_case(p_case_id INT) RETURNS BOOLEAN
READS SQL DATA
BEGIN
    DECLARE v_user INT;
    DECLARE v_role VARCHAR(30);
    SET v_user = fn_cur_user();
    SET v_role = fn_cur_role();

    IF v_user IS NULL THEN RETURN FALSE; END IF;               -- not logged in
    IF v_role IN ('Admin', 'Clerk') THEN RETURN TRUE; END IF;  -- see everything

    IF v_role = 'Judge' THEN
        RETURN EXISTS (SELECT 1 FROM cases c JOIN judges j ON j.judge_id = c.judge_id
                       WHERE c.case_id = p_case_id AND j.user_id = v_user);
    ELSEIF v_role = 'Lawyer' THEN
        RETURN EXISTS (SELECT 1 FROM case_advocates ca JOIN advocates a ON a.advocate_id = ca.advocate_id
                       WHERE ca.case_id = p_case_id AND a.user_id = v_user);
    ELSEIF v_role = 'Client' THEN
        RETURN EXISTS (SELECT 1 FROM case_parties cp JOIN parties p ON p.party_id = cp.party_id
                       WHERE cp.case_id = p_case_id AND p.user_id = v_user);
    END IF;
    RETURN FALSE;
END//


CREATE PROCEDURE sp_log(IN p_action VARCHAR(50), IN p_table VARCHAR(50),
                        IN p_record INT, IN p_details VARCHAR(500))
BEGIN
    INSERT INTO audit_log (user_id, action, table_name, record_id, details)
    VALUES (fn_cur_user(), p_action, p_table, p_record, p_details);
END//


CREATE PROCEDURE sp_require(IN p_option INT)
BEGIN
    DECLARE v_user    INT;
    DECLARE v_role_id INT;
    DECLARE v_must    BOOLEAN DEFAULT FALSE;
    DECLARE v_msg     VARCHAR(200);

    -- Check 1: is somebody logged in?
    SET v_user = fn_cur_user();
    IF v_user IS NULL THEN
        SET v_msg = 'Access denied: please login first - CALL sp_login(email, password);';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- Check 2: is this person still using a temporary password?
    SELECT must_change_password INTO v_must FROM users WHERE user_id = v_user;
    IF v_must AND p_option NOT IN (23, 24) THEN
        SET v_msg = 'You must change your temporary password first - CALL sp_change_password(old_password, new_password);';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- Check 3: is this menu option allowed for this person's role?
    SET v_role_id = fn_cur_role_id();
    IF NOT EXISTS (SELECT 1 FROM role_permissions
                   WHERE role_id = v_role_id AND option_no = p_option) THEN
        CALL sp_log('ACCESS_DENIED', 'menu_options', p_option,
                    CONCAT(fn_cur_role(), ' tried menu option ', p_option));
        SET v_msg = CONCAT('Access denied: the ', fn_cur_role(),
                           ' role is not allowed to use option ', p_option, '.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- All checks passed: note the time so the login does not expire.
    UPDATE active_sessions SET last_activity = NOW() WHERE connection_id = CONNECTION_ID();
END//

-- -----------------------------------------------------
-- Second guard for procedures that work on ONE case:
-- the case must exist AND this person must be allowed to see it.
-- -----------------------------------------------------
CREATE PROCEDURE sp_require_case(IN p_case_id INT)
BEGIN
    DECLARE v_msg VARCHAR(200);

    IF NOT EXISTS (SELECT 1 FROM cases WHERE case_id = p_case_id) THEN
        SET v_msg = 'Case not found.';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    ELSEIF NOT fn_can_view_case(p_case_id) THEN
        CALL sp_log('ACCESS_DENIED', 'cases', p_case_id,
                    CONCAT(fn_cur_role(), ' blocked from case ', p_case_id));
        SET v_msg = 'Access denied: you are not connected with this case.';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END//

-- =====================================================
-- LOGIN
--   CALL sp_login('email', 'password');
-- Three wrong passwords in a row lock the account for 15 minutes.
-- =====================================================
CREATE PROCEDURE sp_login(IN p_email VARCHAR(100), IN p_password VARCHAR(100))
BEGIN
    -- these variables hold the user's details after we look them up
    DECLARE v_id      INT DEFAULT NULL;
    DECLARE v_role_id INT;
    DECLARE v_role    VARCHAR(30);
    DECLARE v_name    VARCHAR(100);
    DECLARE v_hash    CHAR(64);
    DECLARE v_salt    CHAR(32);
    DECLARE v_active  BOOLEAN;
    DECLARE v_must    BOOLEAN DEFAULT FALSE;
    DECLARE v_fail    INT;
    DECLARE v_locked  DATETIME;

    -- Step 1: forget any earlier login on this connection, and clean old sessions
	DELETE FROM active_sessions WHERE connection_id = CONNECTION_ID();
    DELETE FROM active_sessions
    WHERE connection_id > 0 AND last_activity < (NOW() - INTERVAL 30 MINUTE);

    -- Step 2: find the user by email
    SELECT u.user_id, u.role_id, r.role_name, u.full_name, u.password_hash,
           u.password_salt, u.is_active, u.must_change_password,
           u.failed_attempts, u.locked_until
    INTO   v_id, v_role_id, v_role, v_name, v_hash,
           v_salt, v_active, v_must,
           v_fail, v_locked
    FROM users u JOIN roles r ON r.role_id = u.role_id
    WHERE u.email = p_email;

    -- Step 3: decide what happens
    IF v_id IS NULL THEN
        -- no such email (we do not say which part was wrong)
        CALL sp_log('LOGIN_FAILED', 'users', NULL, CONCAT('Unknown email: ', LEFT(p_email, 100)));
        SELECT 'Invalid email or password.' AS Result;

    ELSEIF NOT v_active THEN
        CALL sp_log('LOGIN_FAILED', 'users', v_id, 'Account is disabled');
        SELECT 'This account is disabled. Contact the administrator.' AS Result;

    ELSEIF v_locked IS NOT NULL AND v_locked > NOW() THEN
        CALL sp_log('LOGIN_FAILED', 'users', v_id, 'Account is locked');
        SELECT CONCAT('Account locked until ', v_locked, '. Try again later.') AS Result;

    ELSEIF SHA2(CONCAT(v_salt, p_password), 256) = v_hash THEN
        -- CORRECT PASSWORD: remember this connection belongs to this user
        INSERT INTO active_sessions (connection_id, user_id, role_id)
        VALUES (CONNECTION_ID(), v_id, v_role_id);

        UPDATE users SET failed_attempts = 0, locked_until = NULL, last_login = NOW()
        WHERE user_id = v_id;

        CALL sp_log('LOGIN', 'users', v_id, 'Login successful');
        SELECT CONCAT('Login successful. Welcome, ', v_name, ' (', v_role, ')') AS Result;

        IF v_must THEN
            SELECT 'IMPORTANT: you are using a temporary password. Change it now: CALL sp_change_password(old_password, new_password);' AS Notice;
        END IF;
        CALL sp_main_menu();

    ELSE
        -- WRONG PASSWORD: count the failure; lock the account after 3
        SET v_fail = v_fail + 1;
        IF v_fail >= 3 THEN
            UPDATE users SET failed_attempts = 0, locked_until = NOW() + INTERVAL 15 MINUTE
            WHERE user_id = v_id;
            CALL sp_log('ACCOUNT_LOCKED', 'users', v_id, '3 wrong passwords - locked 15 minutes');
            SELECT 'Too many failed attempts. Account locked for 15 minutes.' AS Result;
        ELSE
            UPDATE users SET failed_attempts = v_fail WHERE user_id = v_id;
            CALL sp_log('LOGIN_FAILED', 'users', v_id, 'Wrong password');
            SELECT CONCAT('Invalid email or password. Attempts left: ', 3 - v_fail) AS Result;
        END IF;
    END IF;
END//

-- =====================================================
-- LOGOUT
-- =====================================================
CREATE PROCEDURE sp_logout()
BEGIN
    IF fn_cur_user() IS NULL THEN
        SELECT 'You are not logged in.' AS Result;
    ELSE
        CALL sp_log('LOGOUT', 'users', fn_cur_user(), 'Logged out');
        DELETE FROM active_sessions WHERE connection_id = CONNECTION_ID();
        SELECT 'Logged out successfully.' AS Result;
    END IF;
END//

-- =====================================================
-- OPTION 23 : CHANGE MY PASSWORD
--   CALL sp_change_password('old password', 'new password');
-- Also clears the "temporary password" flag.
-- =====================================================
CREATE PROCEDURE sp_change_password(IN p_old VARCHAR(100), IN p_new VARCHAR(100))
BEGIN
    DECLARE v_user     INT;
    DECLARE v_hash     CHAR(64);
    DECLARE v_salt     CHAR(32);
    DECLARE v_new_salt CHAR(32);

    -- if anything goes wrong inside, show "ERROR: ..." instead of crashing
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @err_msg = MESSAGE_TEXT;
        SELECT CONCAT('ERROR: ', @err_msg) AS Result;
    END;

    CALL sp_require(23);
    SET v_user = fn_cur_user();
    SELECT password_hash, password_salt INTO v_hash, v_salt FROM users WHERE user_id = v_user;

    IF SHA2(CONCAT(v_salt, p_old), 256) <> v_hash THEN
        CALL sp_log('PASSWORD_CHANGE_FAILED', 'users', v_user, 'Wrong old password');
        SELECT 'ERROR: old password is incorrect.' AS Result;
    ELSEIF p_new = p_old THEN
        SELECT 'ERROR: the new password must be different from the old one.' AS Result;
    ELSEIF CHAR_LENGTH(p_new) < 8 OR p_new NOT REGEXP '[0-9]' OR p_new NOT REGEXP '[A-Za-z]' THEN
        SELECT 'ERROR: new password needs at least 8 characters with letters and digits.' AS Result;
    ELSE
        SET v_new_salt = REPLACE(UUID(), '-', '');      -- a fresh random salt
        UPDATE users SET password_salt = v_new_salt,
                         password_hash = SHA2(CONCAT(v_new_salt, p_new), 256),
                         must_change_password = FALSE
        WHERE user_id = v_user;
        CALL sp_log('PASSWORD_CHANGED', 'users', v_user, 'Password changed');
        SELECT 'Password changed successfully.' AS Result;
    END IF;
END//

DELIMITER ;