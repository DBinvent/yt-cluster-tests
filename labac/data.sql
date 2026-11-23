-- [labac] The test rows, the same in app_lsr and app_rls. The expectations of 50_queries.sh are
-- worked out from these by hand - change both together.
--
TRUNCATE docs, tasks, notices, projects;
-- projects: the department and the security access level (sal) of each
INSERT INTO projects (id, dept, sal, name) VALUES
    (1, 'sales', 1,    'sales, open'),
    (2, 'sales', 3,    'sales, secret'),
    (3, 'eng',   2,    'eng, restricted'),
    (4, 'eng',   4,    'eng, top secret'),
    (5, 'hr',    1,    'hr, open'),
    (6, 'hr',    NULL, 'hr, no level said');
-- docs: the project's department and sal, and a review level of their own
INSERT INTO docs (id, project_id, review, title) VALUES
    (10, 1, 1,    'p1, review 1'),
    (11, 1, 3,    'p1, review 3'),
    (20, 2, 1,    'p2, review 1'),
    (30, 3, 1,    'p3, review 1'),
    (40, 4, 2,    'p4, review 2'),
    (50, 5, NULL, 'p5, no review level said'),
    (60, 6, 1,    'p6, review 1');
-- tasks: the project's department; the table declares no level of its own
INSERT INTO tasks (id, project_id, title) VALUES
    (100, 1, 'of p1'), (101, 2, 'of p2'), (102, 3, 'of p3'), (103, 5, 'of p5'), (104, 6, 'of p6'), (105, 4, 'of p4');
-- notices: a level alone
INSERT INTO notices (id, sal, body) VALUES
    (1, 1, 'sal 1'), (2, 2, 'sal 2'), (3, 3, 'sal 3'), (4, 4, 'sal 4'), (5, NULL, 'no level said');
