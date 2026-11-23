
USE court_cms;

DROP PROCEDURE IF EXISTS sp_main_menu;
DROP PROCEDURE IF EXISTS sp_menu;

DELIMITER //

CREATE PROCEDURE sp_main_menu()
BEGIN
    DECLARE v_user INT;
    DECLARE v_must BOOLEAN DEFAULT FALSE;
    SET v_user = fn_cur_user();

    IF v_user IS NULL THEN
        -- nobody is logged in yet
        SELECT 'NOT LOGGED IN' AS Status,
               'CALL sp_login(''your_email'', ''your_password'');' AS `How to log in`;
    ELSE
        -- first box: who you are
        SELECT CONCAT('Logged in as ', u.full_name, ' (', r.role_name, ')') AS `Current session`
        FROM users u JOIN roles r ON r.role_id = u.role_id
        WHERE u.user_id = v_user;

        -- a reminder if the password is still temporary
        SELECT must_change_password INTO v_must FROM users WHERE user_id = v_user;
        IF v_must THEN
            SELECT 'You must change your temporary password first: CALL sp_change_password(old_password, new_password);' AS Notice;
        END IF;

        -- second box: only the options this role is allowed to use
        SELECT o.option_no AS `Option`, o.category AS Category,
               o.description AS Description, o.usage_text AS `How to run`
        FROM menu_options o
        JOIN role_permissions rp ON rp.option_no = o.option_no
        WHERE rp.role_id = fn_cur_role_id()
        ORDER BY o.option_no;
    END IF;
END//

CREATE PROCEDURE sp_menu(IN p_choice INT, IN p_arg VARCHAR(100))
BEGIN
    CASE p_choice
        -- options that take zero or one input
        WHEN 7  THEN CALL sp_cause_list(IFNULL(STR_TO_DATE(p_arg, '%Y-%m-%d'), CURDATE()));
        WHEN 8  THEN CALL sp_upcoming_hearings(IFNULL(CAST(p_arg AS UNSIGNED), 7));
        WHEN 9  THEN CALL sp_search_case(IFNULL(p_arg, ''));
        WHEN 10 THEN CALL sp_case_details(CAST(p_arg AS UNSIGNED));
        WHEN 11 THEN CALL sp_case_timeline(CAST(p_arg AS UNSIGNED));
        WHEN 12 THEN CALL sp_pending_vs_disposed();
        WHEN 13 THEN CALL sp_cases_by_type();
        WHEN 14 THEN CALL sp_judge_workload();
        WHEN 15 THEN CALL sp_cases_without_hearing();
        WHEN 16 THEN CALL sp_status_history(CAST(p_arg AS UNSIGNED));
        WHEN 17 THEN CALL sp_generate_reminders();
        WHEN 18 THEN CALL sp_view_notifications();
        WHEN 21 THEN CALL sp_view_audit(IFNULL(CAST(p_arg AS UNSIGNED), 50));
        WHEN 22 THEN CALL sp_list_users();
        WHEN 24 THEN CALL sp_logout();
        WHEN 27 THEN CALL sp_pending_requests();
        WHEN 30 THEN CALL sp_my_requests();

        -- options that need many inputs: just explain how to call them
        WHEN 1  THEN SELECT 'Option 1 needs several inputs. Use: CALL sp_add_case(...)  (see CALL sp_main_menu();)' AS Message;
        WHEN 2  THEN SELECT 'Option 2 needs several inputs. Use: CALL sp_add_party_to_case(...)' AS Message;
        WHEN 3  THEN SELECT 'Option 3 needs several inputs. Use: CALL sp_schedule_hearing(...)' AS Message;
        WHEN 4  THEN SELECT 'Option 4 needs several inputs. Use: CALL sp_record_outcome(...)' AS Message;
        WHEN 5  THEN SELECT 'Option 5 needs several inputs. Use: CALL sp_update_case_status(...)' AS Message;
        WHEN 6  THEN SELECT 'Option 6 needs several inputs. Use: CALL sp_add_document(...)' AS Message;
        WHEN 19 THEN SELECT 'Option 19 needs several inputs. Use: CALL sp_create_user(...)' AS Message;
        WHEN 20 THEN SELECT 'Option 20 needs several inputs. Use: CALL sp_set_user_active(...)' AS Message;
        WHEN 23 THEN SELECT 'Option 23 needs two inputs. Use: CALL sp_change_password(old, new)' AS Message;
        WHEN 25 THEN SELECT 'Option 25 needs several inputs. Use: CALL sp_assign_advocate(...)' AS Message;
        WHEN 26 THEN SELECT 'Option 26 needs inputs. Use: CALL sp_request_case_link(case_number, note)' AS Message;
        WHEN 28 THEN SELECT 'Option 28 needs inputs. Use: CALL sp_decide_link_request(request_id, party_id, ''Approve'')' AS Message;
        WHEN 29 THEN SELECT 'Option 29 needs inputs. Use: CALL sp_reset_password(user_id, temp_password)' AS Message;
        ELSE SELECT 'Invalid option. Run CALL sp_main_menu(); to see the options for your role.' AS Message;
    END CASE;
END//

DELIMITER ;
