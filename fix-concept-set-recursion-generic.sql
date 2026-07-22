-- ============================================================================
-- Generic concept_set recursion / cycle fix.
--
-- Purpose:
--   Detect and break ANY circular reference in the concept_set graph that
--   causes infinite recursion when OpenMRS expands nested sets. This is the
--   root cause of the HTTP 500:
--       "Handler dispatch failed; nested exception is
--        java.lang.StackOverflowError"
--   seen when loading pages that walk nested LabSets / ConvSets / Sets
--   (e.g. the Results / ObsTree views).
--
--   Unlike the earlier targeted scripts (remove-cbc-members.sql,
--   remove-laboratory-order-*.sql, fix-semen-analysis-*.sql,
--   fix-concept-set-recursion-known-issues.sql), this script is NOT scoped to
--   specific concepts. It scans the WHOLE concept_set graph and removes only
--   the membership edges that actually participate in a cycle.
--
-- Safety properties:
--   - Removes membership LINKS only. It never deletes concepts.
--   - Every removed row is backed up to concept_set_backup_cycle_autofix.
--   - It ONLY removes an edge while that edge is still closing a real loop,
--     so legitimate (acyclic) hierarchy is never touched.
--   - Idempotent: re-running on clean data removes nothing.
--   - Portable: no hardcoded concept_id / uuid values.
--
-- How cycles are broken:
--   1. All self-loops (concept_set = concept_id) are removed first.
--   2. Then, repeatedly: find one edge (parent -> child) where the child can
--      reach the parent again through the graph (i.e. it closes a cycle),
--      remove it, and re-check. Among candidate edges we prefer the one whose
--      child has the LARGEST subtree, i.e. the link pointing back "up" to a
--      broad ancestor/root set -- that is the erroneous reverse link, not the
--      legitimate set -> member link.
--
-- Run in MySQL against the openmrs database. Take a backup first (see the
-- companion docs / mysqldump command at the bottom of this file).
-- ============================================================================

SET SESSION cte_max_recursion_depth = 1000000;

-- ----------------------------------------------------------------------------
-- Backup table for every membership edge this script removes.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS concept_set_backup_cycle_autofix (
  backup_id         INT NOT NULL AUTO_INCREMENT,
  concept_set_id    INT NOT NULL,
  concept_id        INT NOT NULL,
  concept_set       INT NOT NULL,
  sort_weight       DOUBLE NULL,
  creator           INT NOT NULL,
  date_created      DATETIME NULL,
  uuid              CHAR(38) NOT NULL,
  backup_reason     VARCHAR(120) NOT NULL,
  backup_run_id     VARCHAR(40) NOT NULL,
  backup_created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (backup_id),
  KEY idx_csbca_concept_set_id (concept_set_id),
  KEY idx_csbca_concept_id     (concept_id),
  KEY idx_csbca_concept_set    (concept_set),
  KEY idx_csbca_run            (backup_run_id)
);

-- ----------------------------------------------------------------------------
-- Backup table for is_set flips (concepts that become empty after the fix).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS concept_is_set_backup_cycle_autofix (
  backup_id         INT NOT NULL AUTO_INCREMENT,
  concept_id        INT NOT NULL,
  uuid              CHAR(38) NOT NULL,
  concept_name      VARCHAR(255) NULL,
  class_name        VARCHAR(255) NULL,
  is_set_before     TINYINT NOT NULL,
  backup_run_id     VARCHAR(40) NOT NULL,
  backup_created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (backup_id),
  KEY idx_cisbca_concept_id (concept_id),
  KEY idx_cisbca_run        (backup_run_id)
);

-- ----------------------------------------------------------------------------
-- READ-ONLY PREVIEW: how many cycle edges exist right now?
-- (Self-loops + edges whose child can reach the parent again.)
-- ----------------------------------------------------------------------------
SELECT 'self_loops' AS cycle_type, COUNT(*) AS edges
FROM concept_set
WHERE concept_set = concept_id
UNION ALL
SELECT 'multi_node_cycle_edges', COUNT(*) FROM (
  WITH RECURSIVE reach AS (
    SELECT cs.concept_set AS start_node, cs.concept_id AS node
    FROM concept_set cs
    WHERE cs.concept_set <> cs.concept_id
    UNION
    SELECT r.start_node, cs.concept_id
    FROM reach r
    JOIN concept_set cs ON cs.concept_set = r.node
    WHERE cs.concept_set <> cs.concept_id
  )
  SELECT DISTINCT cs.concept_set, cs.concept_id
  FROM concept_set cs
  JOIN reach r
    ON r.start_node = cs.concept_id
   AND r.node       = cs.concept_set
  WHERE cs.concept_set <> cs.concept_id
) AS cyc;

-- ============================================================================
-- The fix is implemented as a stored procedure so it can loop until the
-- graph is acyclic. Removing one edge can resolve several overlapping cycles,
-- so we re-evaluate after every removal.
-- ============================================================================
DROP PROCEDURE IF EXISTS fix_concept_set_cycles;

DELIMITER $$
CREATE PROCEDURE fix_concept_set_cycles(IN p_run_id VARCHAR(40))
BEGIN
  DECLARE v_set     INT;
  DECLARE v_member  INT;
  DECLARE v_guard   INT DEFAULT 0;

  -- --------------------------------------------------------------------------
  -- Step 1: self-loops (a concept that is a member of itself). Always invalid.
  -- --------------------------------------------------------------------------
  INSERT INTO concept_set_backup_cycle_autofix
    (concept_set_id, concept_id, concept_set, sort_weight,
     creator, date_created, uuid, backup_reason, backup_run_id)
  SELECT cs.concept_set_id, cs.concept_id, cs.concept_set, cs.sort_weight,
         cs.creator, cs.date_created, cs.uuid, 'self_loop', p_run_id
  FROM concept_set cs
  WHERE cs.concept_set = cs.concept_id;

  DELETE FROM concept_set WHERE concept_set = concept_id;

  -- --------------------------------------------------------------------------
  -- Step 2: break remaining multi-node cycles one edge at a time.
  -- --------------------------------------------------------------------------
  cycle_loop: LOOP
    SET v_guard = v_guard + 1;
    IF v_guard > 100000 THEN
      -- Safety valve; should never be hit on real data.
      LEAVE cycle_loop;
    END IF;

    SET v_set = NULL;
    SET v_member = NULL;

    -- Find one edge (concept_set -> concept_id) that closes a cycle: the
    -- child can reach the parent again. Prefer the edge whose child has the
    -- largest subtree -- that is the reverse link pointing up to an ancestor.
    WITH RECURSIVE reach AS (
      SELECT cs.concept_set AS start_node, cs.concept_id AS node
      FROM concept_set cs
      WHERE cs.concept_set <> cs.concept_id
      UNION
      SELECT r.start_node, cs.concept_id
      FROM reach r
      JOIN concept_set cs ON cs.concept_set = r.node
      WHERE cs.concept_set <> cs.concept_id
    )
    SELECT cs.concept_set, cs.concept_id
      INTO v_set, v_member
    FROM concept_set cs
    JOIN reach r
      ON r.start_node = cs.concept_id
     AND r.node       = cs.concept_set
    WHERE cs.concept_set <> cs.concept_id
    ORDER BY
      (SELECT COUNT(*) FROM concept_set d WHERE d.concept_set = cs.concept_id) DESC,
      cs.concept_id DESC
    LIMIT 1;

    IF v_set IS NULL THEN
      LEAVE cycle_loop;
    END IF;

    -- Back up the chosen edge, then delete it.
    INSERT INTO concept_set_backup_cycle_autofix
      (concept_set_id, concept_id, concept_set, sort_weight,
       creator, date_created, uuid, backup_reason, backup_run_id)
    SELECT cs.concept_set_id, cs.concept_id, cs.concept_set, cs.sort_weight,
           cs.creator, cs.date_created, cs.uuid, 'cycle_back_edge', p_run_id
    FROM concept_set cs
    WHERE cs.concept_set = v_set
      AND cs.concept_id  = v_member;

    DELETE FROM concept_set
    WHERE concept_set = v_set
      AND concept_id  = v_member;
  END LOOP;
END$$
DELIMITER ;

-- ----------------------------------------------------------------------------
-- Run the fix. Use a timestamp-based run id so each run is auditable.
-- ----------------------------------------------------------------------------
START TRANSACTION;

SET @run_id := DATE_FORMAT(NOW(), '%Y%m%d-%H%i%s');
CALL fix_concept_set_cycles(@run_id);

-- --------------------------------------------------------------------------
-- Step 3: any concept that LOST all of its members because of this run and
-- still has is_set = 1 should be flipped to is_set = 0. Scoped strictly to
-- concepts we actually touched, so unrelated empty sets are left alone.
-- --------------------------------------------------------------------------
INSERT INTO concept_is_set_backup_cycle_autofix
  (concept_id, uuid, concept_name, class_name, is_set_before, backup_run_id)
SELECT DISTINCT
  c.concept_id, c.uuid, cn.name, cc.name, c.is_set, @run_id
FROM concept c
JOIN concept_class cc ON cc.concept_class_id = c.class_id
LEFT JOIN concept_name cn
  ON cn.concept_id = c.concept_id
 AND cn.concept_name_type = 'FULLY_SPECIFIED'
 AND cn.locale = 'en'
 AND cn.voided = 0
WHERE c.is_set = 1
  AND c.retired = 0
  AND c.concept_id IN (
        SELECT concept_set FROM concept_set_backup_cycle_autofix
        WHERE backup_run_id = @run_id
      )
  AND NOT EXISTS (
        SELECT 1 FROM concept_set cs2 WHERE cs2.concept_set = c.concept_id
      );

UPDATE concept c
JOIN concept_is_set_backup_cycle_autofix b
  ON b.concept_id = c.concept_id
 AND b.backup_run_id = @run_id
SET c.is_set = 0
WHERE c.is_set = 1;

COMMIT;

DROP PROCEDURE IF EXISTS fix_concept_set_cycles;

-- ============================================================================
-- SUMMARY of what this run changed.
-- ============================================================================
SELECT backup_reason, COUNT(*) AS edges_removed
FROM concept_set_backup_cycle_autofix
WHERE backup_run_id = @run_id
GROUP BY backup_reason
ORDER BY backup_reason;

SELECT COUNT(*) AS total_edges_removed
FROM concept_set_backup_cycle_autofix
WHERE backup_run_id = @run_id;

SELECT COUNT(*) AS concepts_flipped_to_is_set_0
FROM concept_is_set_backup_cycle_autofix
WHERE backup_run_id = @run_id;

-- ============================================================================
-- VERIFICATION -- both numbers must be 0 after a successful run.
-- ============================================================================
SELECT COUNT(*) AS remaining_self_loops
FROM concept_set
WHERE concept_set = concept_id;

SELECT COUNT(*) AS remaining_cycle_edges FROM (
  WITH RECURSIVE reach AS (
    SELECT cs.concept_set AS start_node, cs.concept_id AS node
    FROM concept_set cs
    WHERE cs.concept_set <> cs.concept_id
    UNION
    SELECT r.start_node, cs.concept_id
    FROM reach r
    JOIN concept_set cs ON cs.concept_set = r.node
    WHERE cs.concept_set <> cs.concept_id
  )
  SELECT DISTINCT cs.concept_set, cs.concept_id
  FROM concept_set cs
  JOIN reach r
    ON r.start_node = cs.concept_id
   AND r.node       = cs.concept_set
  WHERE cs.concept_set <> cs.concept_id
) AS cyc;

-- ============================================================================
-- RUN / RESTORE NOTES (PowerShell + Docker)
-- ----------------------------------------------------------------------------
-- 1) Full backup first:
--    docker exec ethiopiaemr-distro-referenceapplication-db-1 mysqldump -uroot -popenmrs --single-transaction --routines --triggers openmrs > backups/openmrs-full-<timestamp>.sql
--
-- 2) Run this script:
--    Get-Content -Raw "scripts/fix-concept-set-recursion-generic.sql" | docker exec -i ethiopiaemr-distro-referenceapplication-db-1 mysql -uroot -popenmrs openmrs
--
-- 3) Restore ONLY the edges removed by a given run (if ever needed):
--    INSERT INTO concept_set (concept_set, concept_id, sort_weight, creator, date_created, uuid)
--    SELECT concept_set, concept_id, sort_weight, creator, date_created, uuid
--    FROM concept_set_backup_cycle_autofix
--    WHERE backup_run_id = '<run_id printed above>';
--    -- and restore is_set flips from concept_is_set_backup_cycle_autofix similarly.
-- ============================================================================
