-- ============================================================
-- app_users.role — CHECK constraint
-- Restricts the role text column to the canonical staff role
-- values plus the 'client' pseudo-role used for portal accounts.
--
-- BEFORE APPLYING: verify no existing rows violate this list.
-- Run the audit query first:
--
--   SELECT role, COUNT(*) FROM app_users GROUP BY role ORDER BY 2 DESC;
--
-- If any value falls outside the list below, either:
--   1. UPDATE the offending rows to a canonical value, OR
--   2. Add the legacy value to the list before applying this migration.
--
-- This migration is idempotent (DROP IF EXISTS first) and safe to
-- re-run after extending the list to add a new role.
-- ============================================================

ALTER TABLE app_users
  DROP CONSTRAINT IF EXISTS app_users_role_check;

ALTER TABLE app_users
  ADD CONSTRAINT app_users_role_check CHECK (role IN (
    'managing_director',
    'operations_director',
    'business_analyst',
    'quality_compliance',
    'financial_controller',
    'commercial_manager',
    'ecommerce_manager',
    'production_manager',
    'warehouse_liquid',
    'client_coordinator',
    'production_operator',
    'order_fulfillment',
    'client'
  ));
