# Court Case Management & Legal Hearing Tracking System

A MySQL-based **Court Case Management System (CMS)** designed to manage legal cases, parties, advocates, judges, hearings, documents, case status updates, and client access through stored procedures, triggers, and role-based access control.

The project simulates the workflow of a court administration system, from case registration to hearing scheduling, status tracking, and client access management.

---

## Overview

The system provides a centralized database for managing court proceedings and related records. It uses MySQL stored procedures to handle data-entry operations, functions to identify the current user and role, and triggers to automate activities such as audit logging and case-status tracking.

It also implements a role-based security model in which different users have different permissions and access to system operations.

## Features

- **Case Management** — Register, search, and maintain civil, criminal, family, and property cases.
- **Hearing Management** — Schedule court hearings, manage hearing details, and prevent scheduling conflicts.
- **Party Management** — Maintain plaintiffs, defendants, petitioners, respondents, and other parties involved in cases.
- **Advocate Assignment** — Assign advocates to cases and their respective parties.
- **Document Management** — Maintain records of case documents and their associated file paths.
- **Case Status Tracking** — Track case progress and maintain a history of status changes.
- **User Management** — Create and manage accounts for administrators, judges, lawyers, clerks, and clients.
- **Client Registration & Linking** — Allow clients to register and request access to their cases, subject to verification and approval.
- **Notifications** — Generate and manage hearing reminders and notifications.
- **Audit Logging** — Record important database actions for accountability and traceability.
- **Role-Based Access Control** — Restrict system operations based on user roles and permissions.
- **Authentication & Session Management** — Password hashing, login validation, session tracking, account controls, and password management.

## User Roles

| Role | Responsibilities |
|---|---|
| Admin | Manage staff accounts, users, system access, and administrative operations |
| Judge | Access assigned cases and relevant judicial information |
| Lawyer | Access assigned cases, manage relevant documents, and track hearings |
| Clerk | Register cases, manage parties, schedule hearings, and maintain case records |
| Client | Register, request linking to a case, and access approved case information |

## Database Structure

The database is organized into relational tables to maintain structured records and relationships between users, cases, hearings, and other entities.

### Core Tables

| Table | Description |
|---|---|
| `roles` | Stores available system roles |
| `users` | Stores user accounts and authentication details |
| `judges` | Stores judge-specific information |
| `advocates` | Stores lawyer-specific information |
| `courtrooms` | Stores courtroom details |
| `case_types` | Stores case categories |
| `cases` | Stores case information and current status |
| `parties` | Stores individuals or entities involved in cases |
| `case_parties` | Connects parties to cases with their respective roles |
| `case_advocates` | Maintains advocate assignments |
| `hearings` | Stores hearing dates, times, courtrooms, and outcomes |
| `documents` | Stores document metadata and file locations |
| `case_status_history` | Tracks changes in case status |
| `notifications` | Stores notifications and reminders |
| `audit_log` | Records important system activities |
| `menu_options` | Defines available system operations |
| `role_permissions` | Maps roles to permitted operations |
| `active_sessions` | Tracks authenticated database sessions |
| `link_requests` | Stores client requests to access cases |

## Technologies Used

- **Database:** MySQL 8.0+
- **SQL:** Stored Procedures, Functions, Triggers, Transactions
- **Security:** Password hashing with SHA-256, salt generation, session validation, role-based permissions
- **Database Concepts:** Relational modeling, primary keys, foreign keys, constraints, joins, indexing, transaction management

## Database Concepts Implemented

### Stored Procedures

Stored procedures encapsulate operations into reusable database routines.

Examples include:

- `sp_login()` — Authenticate a user
- `sp_logout()` — End an active session
- `sp_create_user()` — Create staff accounts
- `sp_register_client()` — Register client accounts
- `sp_add_case()` — Register new cases
- `sp_add_party_to_case()` — Add parties to a case
- `sp_schedule_hearing()` — Schedule hearings
- `sp_record_outcome()` — Record hearing outcomes
- `sp_update_case_status()` — Update case status
- `sp_add_document()` — Add document metadata
- `sp_assign_advocate()` — Assign advocates to parties
- `sp_request_case_link()` — Request client access to a case
- `sp_decide_link_request()` — Approve or reject client linking requests

### Functions

Database functions provide reusable logic for retrieving information about the current authenticated user and their role.

- `fn_cur_user()` — Returns the current authenticated user ID.
- `fn_cur_role()` — Returns the current user's role.
- `fn_cur_role_id()` — Returns the current user's role ID.
- `fn_can_view_case()` — Checks whether a user has access to a case.

### Triggers

Triggers automate database operations and help maintain consistency.

They are used for functionality such as:

- Automatically recording audit entries.
- Tracking case status changes.
- Supporting automated record maintenance.
- Enforcing checks during relevant data modifications.

### Transactions

Critical data-entry operations use transactions to ensure consistency.

```sql
START TRANSACTION;

-- Perform related database operations

COMMIT;
```

If an operation fails, the transaction can be rolled back so that incomplete changes are not saved.

## Authentication & Security

The system includes several security mechanisms:

- Password hashing using MySQL `SHA2()`.
- Per-user password salts.
- Password validation rules.
- Temporary passwords and mandatory password-change flags.
- Login attempt tracking and account lockout fields.
- Active session tracking.
- Role-based operation authorization.
- Client case-access verification.
- Audit logging of important operations.

> This project is intended for academic and learning purposes. SHA-256 is not recommended as a standalone password-storage algorithm for production applications; production systems should use a dedicated password hashing algorithm such as Argon2id or bcrypt.

## Client Case Access Workflow

Client access is designed to prevent unauthorized viewing of legal cases.

1. A client registers through the client-registration procedure.
2. The client submits a case-link request using the case number.
3. The request is stored as pending.
4. A clerk or administrator reviews the request.
5. The request is approved or rejected after verification.
6. Upon approval, the client's account is linked to the corresponding party in the case.
7. The client can access permitted case information.

## Example Workflow

A typical case-management workflow looks like this:

```text
Admin Login
    |
    v
Create Staff Accounts
    |
    v
Register a Case
    |
    v
Add Parties to the Case
    |
    v
Assign Advocates
    |
    v
Schedule Hearing
    |
    v
Attach Documents
    |
    v
Update Case Status
    |
    v
Maintain Status History & Audit Logs
    |
    v
Client Requests Case Access
    |
    v
Clerk Approves / Rejects Request
```

## Reports & Queries

The system supports operations and reports such as:

- Cause list by date
- Upcoming hearings
- Case search
- Case details
- Case timeline
- Pending vs. disposed cases
- Cases grouped by type
- Judge workload
- Cases without scheduled hearings
- Case status history
- Notifications
- Audit log
- User listing
- Pending client-link requests

## Setup & Installation

### 1. Install MySQL

Install MySQL Server 8.0 or later and a SQL client such as MySQL Workbench.

### 2. Create the Database

Run the project schema file to create the database and tables.

```sql
SOURCE 01_schema.sql;
```

### 3. Run the SQL Files in Order

Execute the SQL project files in the prescribed order, as later files depend on tables, functions, procedures, triggers, and seed data created in earlier files.

### 4. Verify Installation

```sql
USE court_cms;

SHOW TABLES;
```

### 5. Login

Use one of the initial administrator accounts created by the sample-data script.

```sql
CALL sp_login('admin1@court.in', 'Admin@123');
```

### 6. View the System Menu

```sql
CALL sp_main_menu();
```

### 7. Execute Operations

Use the appropriate stored procedure for each operation. For example:

```sql
CALL sp_add_case(
    'CIV/2026/0201',
    'Sample Property Dispute',
    1,
    'A sample case created for testing the system.',
    CURDATE(),
    'Normal',
    1
);
```

> Make sure the user is logged in with a role authorized to perform the operation and that referenced IDs exist in the database.

## Sample Data

The project includes reference data such as:

- System roles
- Case types
- Courtrooms
- Initial administrator accounts

Additional test data can be created using the system's stored procedures for users, cases, parties, hearings, advocates, documents, and client requests.

## Project Objectives

- Apply relational database design concepts to a practical domain.
- Implement database-level business logic using stored procedures.
- Automate database operations using triggers.
- Use functions to simplify authentication and authorization logic.
- Maintain data consistency using constraints and transactions.
- Implement role-based permissions and session management.
- Understand relationships between multiple interconnected entities.
- Build a realistic SQL-only backend workflow for court administration.

## Future Enhancements

- Web-based dashboard for administrators, judges, lawyers, clerks, and clients.
- Frontend integration with React.
- Backend API using Node.js and Express.
- Actual document uploads and secure file storage.
- Email and SMS hearing notifications.
- Advanced search and filtering.
- Dashboard analytics and visual reports.
- Improved password hashing using Argon2id or bcrypt.
- More granular permission management.

## Disclaimer

This project is an academic database simulation. It is not an official court system and does not process real legal cases, official documents, or confidential court information.

---

**Built as a database management project to explore SQL, relational database design, automation, transactions, and access control in a real-world inspired application.**
