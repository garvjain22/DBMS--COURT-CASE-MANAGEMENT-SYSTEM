
USE court_cms;

INSERT IGNORE INTO roles (role_name) VALUES ('Admin'),('Judge'),('Lawyer'),('Clerk'),('Client');
INSERT IGNORE INTO case_types (type_name) VALUES ('Civil'),('Criminal'),('Family'),('Property');
INSERT IGNORE INTO courtrooms (room_number, floor_no, capacity) VALUES ('101',1,50),('102',1,40),('201',2,60);


REPLACE INTO menu_options (option_no, category, description, usage_text) VALUES
( 1,'DATA ENTRY','Register a new case',                  'CALL sp_add_case(case_no, title, case_type_id, description, filing_date, priority, judge_id);'),
( 2,'DATA ENTRY','Add a party to a case',                'CALL sp_add_party_to_case(case_id, party_name, address, phone, role, client_user_id_or_NULL);'),
( 3,'DATA ENTRY','Schedule a hearing (clash checked)',   'CALL sp_schedule_hearing(case_id, judge_id, courtroom_id, date, start_time, end_time, purpose);'),
( 4,'DATA ENTRY','Record hearing outcome / adjourn',     'CALL sp_record_outcome(hearing_id, status, notes, adjournment_reason, next_date);'),
( 5,'DATA ENTRY','Update case status',                   'CALL sp_update_case_status(case_id, new_status, remarks);'),
( 6,'DATA ENTRY','Attach a document to a case',          'CALL sp_add_document(case_id, doc_type, file_name, file_path);'),
( 7,'VIEWS',     'Cause list for a date',                'CALL sp_menu(7, ''2026-11-25'');   -- NULL = today'),
( 8,'VIEWS',     'Upcoming hearings (next N days)',      'CALL sp_menu(8, ''7'');            -- NULL = 7 days'),
( 9,'VIEWS',     'Search cases (number/title/party)',    'CALL sp_menu(9, ''Verma'');'),
(10,'VIEWS',     'Full case details (parties+lawyers)',  'CALL sp_menu(10, ''1'');           -- case_id'),
(11,'VIEWS',     'Case timeline (all hearings)',         'CALL sp_menu(11, ''1'');           -- case_id'),
(12,'REPORTS',   'Pending vs disposed report',           'CALL sp_menu(12, NULL);'),
(13,'REPORTS',   'Cases by type',                        'CALL sp_menu(13, NULL);'),
(14,'REPORTS',   'Judge workload',                       'CALL sp_menu(14, NULL);'),
(15,'REPORTS',   'Cases with no future hearing',         'CALL sp_menu(15, NULL);'),
(16,'REPORTS',   'Case status history',                  'CALL sp_menu(16, ''1'');           -- case_id'),
(17,'REPORTS',   'Generate reminders for tomorrow',      'CALL sp_menu(17, NULL);'),
(18,'VIEWS',     'My notifications',                     'CALL sp_menu(18, NULL);'),
(19,'ADMIN',     'Create a staff account',               'CALL sp_create_user(name, email, phone, role, temp_password, extra1, extra2);'),
(20,'ADMIN',     'Activate / deactivate / unlock a user','CALL sp_set_user_active(user_id, 1_or_0);'),
(21,'ADMIN',     'View audit log',                       'CALL sp_menu(21, ''50'');          -- last N entries'),
(22,'ADMIN',     'List users',                           'CALL sp_menu(22, NULL);'),
(23,'ACCOUNT',   'Change my password',                   'CALL sp_change_password(old_password, new_password);'),
(24,'ACCOUNT',   'Logout',                               'CALL sp_menu(24, NULL);'),
(25,'DATA ENTRY','Assign an advocate to a party',        'CALL sp_assign_advocate(case_id, advocate_id, party_id);'),
(26,'MY CASE',   'Ask to be linked to my case',          'CALL sp_request_case_link(case_number, note);'),
(27,'CLIENT LINKS','See pending client link requests',   'CALL sp_menu(27, NULL);'),
(28,'CLIENT LINKS','Approve / reject a link request',    'CALL sp_decide_link_request(request_id, party_id, ''Approve'');   -- or ''Reject'''),
(29,'ADMIN',     'Reset a user''s password',             'CALL sp_reset_password(user_id, temp_password);'),
(30,'MY CASE',   'See my link requests',                 'CALL sp_menu(30, NULL);');

-- ---------------- who may use which option ----------------
DELETE FROM role_permissions WHERE role_id > 0;

INSERT INTO role_permissions (role_id, option_no)
SELECT r.role_id, o.option_no
FROM roles r
JOIN menu_options o ON
     -- Admin: everything except the two client-only options
     (r.role_name = 'Admin'  AND o.option_no NOT IN (26,30))
     -- Clerk: daily work + client link requests
  OR (r.role_name = 'Clerk'  AND o.option_no IN (1,2,3,4,5,6,7,8,9,10,11,12,13,15,16,17,18,23,24,25,27,28))
     -- Judge: own hearings / cases
  OR (r.role_name = 'Judge'  AND o.option_no IN (4,5,7,8,9,10,11,12,13,16,18,23,24))
     -- Lawyer: own clients' cases
  OR (r.role_name = 'Lawyer' AND o.option_no IN (6,7,8,9,10,11,18,23,24))
     -- Client: view only + ask for case link
  OR (r.role_name = 'Client' AND o.option_no IN (7,8,9,10,11,18,23,24,26,30));



-- role_id 1 = Admin. 'pending' is replaced with the real scrambled password below.
INSERT INTO users (role_id, full_name, email, phone, password_hash) VALUES
(1,'Admin One (Registrar)','admin1@court.in','9000000001','pending'),
(1,'Admin Two',            'admin2@court.in','9000000002','pending'),
(1,'Admin Three',          'admin3@court.in','9000000003','pending'),
(1,'Admin Four (IT)',      'admin4@court.in','9000000004','pending');

-- Step 1: give each user their own random salt
UPDATE users SET password_salt = REPLACE(UUID(), '-', '') WHERE user_id > 0;

-- Step 2: store SHA2(salt + 'Admin@123') as the password
UPDATE users SET password_hash = SHA2(CONCAT(password_salt, 'Admin@123'), 256) WHERE user_id > 0;
