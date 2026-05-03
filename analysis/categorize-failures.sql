-- categorize-failures.sql
--
-- Joins three signals to produce a complete failure breakdown:
--   1. PUPDatabase.db -> GamesStats.LastPlayed (one row per AutoQA cycle)
--   2. autoqa-failed-tables.csv -> hangs the janitor force-killed (with dialog text)
--   3. autoqa-crashes.csv -> Application Error events from Windows Event Log
--
-- Run with sqlite3 against a local copy of PUPDatabase.db, after first
-- importing the two CSVs as tables called `hangs` and `crashes`.

.headers on
.mode column

-- ---- import the two CSVs ----
-- These DROP/CREATE/import lines assume the CSVs sit next to the .db file.
DROP TABLE IF EXISTS crashes;
CREATE TABLE crashes (TimeCreated TEXT, FaultingModule TEXT, ExceptionCode TEXT);
.mode csv
.import --skip 1 autoqa-crashes.csv crashes

DROP TABLE IF EXISTS hangs;
CREATE TABLE hangs (KilledAt TEXT, PID INT, AgeMin INT, TableFile TEXT, RamMB INT,
                    WindowClass TEXT, Title TEXT, DialogText TEXT);
.import --skip 1 autoqa-failed-tables.csv hangs

.mode column

-- ---- crash -> table mapping (1:1 by closest LastPlayed within 90s) ----
DROP TABLE IF EXISTS crash_tables;
CREATE TABLE crash_tables AS
WITH ranked AS (
    SELECT
        c.TimeCreated AS CrashTime,
        c.FaultingModule,
        g.GameDisplay,
        g.GameFileName,
        ABS(strftime('%s', s.LastPlayed) - strftime('%s', c.TimeCreated)) AS DeltaSec,
        ROW_NUMBER() OVER (
            PARTITION BY c.TimeCreated
            ORDER BY ABS(strftime('%s', s.LastPlayed) - strftime('%s', c.TimeCreated))
        ) AS rn
    FROM crashes c, GamesStats s
    JOIN Games g ON s.GameID = g.GameID
    WHERE ABS(strftime('%s', s.LastPlayed) - strftime('%s', c.TimeCreated)) <= 90
)
SELECT CrashTime, FaultingModule, GameDisplay, GameFileName, DeltaSec
FROM ranked WHERE rn = 1;

-- ---- summary buckets ----
SELECT '=== HEADLINE NUMBERS ===' AS x;
SELECT 'Total tables attempted'                 AS metric, COUNT(*) AS n FROM GamesStats WHERE NumberPlays > 0;
SELECT 'Total crash events'                     AS metric, COUNT(*) AS n FROM crashes;
SELECT 'Distinct tables that crashed'           AS metric, COUNT(DISTINCT GameFileName) AS n FROM crash_tables;
SELECT 'Hang-and-killed (in hangs CSV)'         AS metric, COUNT(*) AS n FROM hangs;
SELECT 'Pure crashes (not also hung)'           AS metric, COUNT(DISTINCT GameFileName) AS n
  FROM crash_tables WHERE GameFileName NOT IN (SELECT TableFile FROM hangs);
SELECT 'Hangs that also crashed (force-kill)'   AS metric, COUNT(DISTINCT ct.GameFileName) AS n
  FROM crash_tables ct WHERE ct.GameFileName IN (SELECT TableFile FROM hangs);
SELECT 'Silent hangs (modal, no crash event)'   AS metric, COUNT(*) AS n
  FROM hangs h WHERE h.TableFile NOT IN (SELECT GameFileName FROM crash_tables);

SELECT '' AS x;
SELECT '=== FAULTING MODULE ===' AS x;
SELECT FaultingModule, COUNT(*) AS Crashes FROM crash_tables GROUP BY FaultingModule ORDER BY Crashes DESC;

SELECT '' AS x;
SELECT '=== HANG SEVERITY (how far the launch got) ===' AS x;
SELECT
    CASE
        WHEN RamMB = 0       THEN '0 MB (post-mortem entry)'
        WHEN RamMB < 100     THEN '<100 MB (early ROM/VBS error popup)'
        WHEN RamMB < 400     THEN '100-400 MB (mid-load stuck)'
        ELSE '400+ MB (mostly loaded, render hang)'
    END AS Bucket,
    COUNT(*) AS Count
FROM hangs GROUP BY Bucket ORDER BY Count DESC;

SELECT '' AS x;
SELECT '=== TOP DIALOG TEXTS (after janitor v2 captures populate) ===' AS x;
.width 50 60
SELECT
    substr(DialogText, 1, 60) AS DialogPreview,
    COUNT(*) AS n
FROM hangs WHERE DialogText IS NOT NULL AND DialogText <> ''
GROUP BY DialogPreview ORDER BY n DESC LIMIT 20;

SELECT '' AS x;
SELECT '=== FULL FAILURE LIST ===' AS x;
.width 50 20 30
SELECT
    COALESCE(ct.GameDisplay, h.TableFile) AS Table_,
    COALESCE(ct.FaultingModule, 'hang-no-crash') AS Type,
    COALESCE(ct.CrashTime, h.KilledAt) AS WhenSeen
FROM crash_tables ct
FULL OUTER JOIN hangs h ON ct.GameFileName = h.TableFile
ORDER BY WhenSeen;
