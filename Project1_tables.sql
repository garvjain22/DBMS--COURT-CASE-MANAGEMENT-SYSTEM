DROP DATABASE IF EXISTS court_cms;
CREATE DATABASE court_cms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE court_cms;

-- ---------------------- 1. ROLES & USERS ----------------------
CREATE TABLE roles (
    role_id     INT AUTO_INCREMENT PRIMARY KEY,
    role_name   VARCHAR(30) NOT NULL UNIQUE      
);

CREATE TABLE users (
    user_id          INT AUTO_INCREMENT PRIMARY KEY,
    role_id          INT NOT NULL,
    full_name        VARCHAR(100) NOT NULL,
    email            VARCHAR(100) NOT NULL UNIQUE,
    phone            VARCHAR(15),
    password_hash    CHAR(64) NOT NULL,                 
    password_salt    CHAR(32) NOT NULL DEFAULT '',      
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,     
    must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    failed_attempts  INT NOT NULL DEFAULT 0,            
    locked_until     DATETIME NULL,                     
    last_login       DATETIME NULL,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (role_id) REFERENCES roles(role_id)
);

-- ---------------------- 2. COURT STAFF ----------------------
CREATE TABLE judges (
    judge_id       INT AUTO_INCREMENT PRIMARY KEY,
    user_id        INT NOT NULL UNIQUE,
    designation    VARCHAR(60) NOT NULL,         
    court_name     VARCHAR(100) NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);

CREATE TABLE advocates (
    advocate_id    INT AUTO_INCREMENT PRIMARY KEY,
    user_id        INT NOT NULL UNIQUE,
    bar_council_no VARCHAR(30) NOT NULL UNIQUE,
    specialization VARCHAR(60),
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);

CREATE TABLE courtrooms (
    courtroom_id   INT AUTO_INCREMENT PRIMARY KEY,
    room_number    VARCHAR(10) NOT NULL UNIQUE,
    floor_no       INT,
    capacity       INT
);

-- ---------------------- 3. CASES ----------------------
CREATE TABLE case_types (
    case_type_id   INT AUTO_INCREMENT PRIMARY KEY,
    type_name      VARCHAR(50) NOT NULL UNIQUE   
);

CREATE TABLE cases (
    case_id        INT AUTO_INCREMENT PRIMARY KEY,
    case_number    VARCHAR(30) NOT NULL UNIQUE,  
    title          VARCHAR(200) NOT NULL,
    case_type_id   INT NOT NULL,
    description    TEXT,
    filing_date    DATE NOT NULL,
    status         ENUM('Filed','Under Hearing','Adjourned','Judgment Reserved','Disposed','Appeal')
                   NOT NULL DEFAULT 'Filed',
    priority       ENUM('Low','Normal','High','Urgent') NOT NULL DEFAULT 'Normal',
    judge_id       INT,                          
    disposed_date  DATE,
    created_by     INT NOT NULL,                 
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (case_type_id) REFERENCES case_types(case_type_id),
    FOREIGN KEY (judge_id)     REFERENCES judges(judge_id),
    FOREIGN KEY (created_by)   REFERENCES users(user_id),
    INDEX idx_case_status (status),
    INDEX idx_case_filing (filing_date)
);

CREATE TABLE parties (
    party_id       INT AUTO_INCREMENT PRIMARY KEY,
    user_id        INT,                          
    party_name     VARCHAR(100) NOT NULL,
    address        VARCHAR(255),
    phone          VARCHAR(15),
    email          VARCHAR(100),
    FOREIGN KEY (user_id) REFERENCES users(user_id)
);


CREATE TABLE case_parties (
    case_id        INT NOT NULL,
    party_id       INT NOT NULL,
    party_role     ENUM('Plaintiff','Defendant','Petitioner','Respondent','Accused','Complainant') NOT NULL,
    PRIMARY KEY (case_id, party_id),
    FOREIGN KEY (case_id)  REFERENCES cases(case_id)   ON DELETE CASCADE,
    FOREIGN KEY (party_id) REFERENCES parties(party_id)
);


CREATE TABLE case_advocates (
    case_id        INT NOT NULL,
    advocate_id    INT NOT NULL,
    party_id       INT NOT NULL,
    PRIMARY KEY (case_id, advocate_id, party_id),
    FOREIGN KEY (case_id)     REFERENCES cases(case_id)       ON DELETE CASCADE,
    FOREIGN KEY (advocate_id) REFERENCES advocates(advocate_id),
    FOREIGN KEY (party_id)    REFERENCES parties(party_id)
);


CREATE TABLE hearings (
    hearing_id     INT AUTO_INCREMENT PRIMARY KEY,
    case_id        INT NOT NULL,
    judge_id       INT NOT NULL,
    courtroom_id   INT NOT NULL,
    hearing_date   DATE NOT NULL,
    start_time     TIME NOT NULL,
    end_time       TIME NOT NULL,
    purpose        VARCHAR(100),                 
    status         ENUM('Scheduled','Completed','Adjourned','Cancelled') NOT NULL DEFAULT 'Scheduled',
    outcome_notes  TEXT,                         
    adjournment_reason VARCHAR(255),
    next_hearing_date  DATE,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (case_id)      REFERENCES cases(case_id)       ON DELETE CASCADE,
    FOREIGN KEY (judge_id)     REFERENCES judges(judge_id),
    FOREIGN KEY (courtroom_id) REFERENCES courtrooms(courtroom_id),
    CHECK (end_time > start_time),
    INDEX idx_hearing_date (hearing_date),
    INDEX idx_hearing_judge_date (judge_id, hearing_date),
    INDEX idx_hearing_room_date (courtroom_id, hearing_date)
);

-- ---------------------- 5. DOCUMENTS ----------------------
CREATE TABLE documents (
    document_id    INT AUTO_INCREMENT PRIMARY KEY,
    case_id        INT NOT NULL,
    hearing_id     INT,                          
    doc_type       ENUM('Petition','Evidence','Order','Judgment','Affidavit','Other') NOT NULL,
    file_name      VARCHAR(255) NOT NULL,
    file_path      VARCHAR(500) NOT NULL,
    uploaded_by    INT NOT NULL,
    uploaded_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (case_id)     REFERENCES cases(case_id) ON DELETE CASCADE,
    FOREIGN KEY (hearing_id)  REFERENCES hearings(hearing_id) ON DELETE SET NULL,
    FOREIGN KEY (uploaded_by) REFERENCES users(user_id)
);

-- ---------------------- 6. HISTORY, NOTIFICATIONS, AUDIT ----------------------
CREATE TABLE case_status_history (
    history_id     INT AUTO_INCREMENT PRIMARY KEY,
    case_id        INT NOT NULL,
    old_status     VARCHAR(30),
    new_status     VARCHAR(30) NOT NULL,
    changed_by     INT,
    changed_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    remarks        VARCHAR(255),
    FOREIGN KEY (case_id) REFERENCES cases(case_id) ON DELETE CASCADE
);

CREATE TABLE notifications (
    notification_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id        INT NOT NULL,
    hearing_id     INT,
    message        VARCHAR(255) NOT NULL,
    is_read        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id)    REFERENCES users(user_id),
    FOREIGN KEY (hearing_id) REFERENCES hearings(hearing_id) ON DELETE CASCADE
);

CREATE TABLE audit_log (
    log_id         INT AUTO_INCREMENT PRIMARY KEY,
    user_id        INT,
    action         VARCHAR(50) NOT NULL,        
    table_name     VARCHAR(50) NOT NULL,
    record_id      INT,
    details        VARCHAR(500),
    logged_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------- 7. SECURITY TABLES ----------------------
CREATE TABLE menu_options (
    option_no    INT PRIMARY KEY,
    category     VARCHAR(30)  NOT NULL,
    description  VARCHAR(100) NOT NULL,
    usage_text   VARCHAR(300) NOT NULL
);

CREATE TABLE role_permissions (
    role_id      INT NOT NULL,
    option_no    INT NOT NULL,
    PRIMARY KEY (role_id, option_no),
    FOREIGN KEY (role_id)   REFERENCES roles(role_id),
    FOREIGN KEY (option_no) REFERENCES menu_options(option_no)
);


CREATE TABLE active_sessions (
    connection_id  BIGINT UNSIGNED PRIMARY KEY,
    user_id        INT NOT NULL,
    role_id        INT NOT NULL,
    login_time     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_activity  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);


CREATE TABLE link_requests (
    request_id    INT AUTO_INCREMENT PRIMARY KEY,
    user_id       INT NOT NULL,                  
    case_id       INT NOT NULL,                  
    note          VARCHAR(255),                  
    status        ENUM('Pending','Approved','Rejected') NOT NULL DEFAULT 'Pending',
    requested_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reviewed_by   INT NULL,                      
    reviewed_at   DATETIME NULL,
    FOREIGN KEY (user_id)     REFERENCES users(user_id),
    FOREIGN KEY (case_id)     REFERENCES cases(case_id),
    FOREIGN KEY (reviewed_by) REFERENCES users(user_id)
);

