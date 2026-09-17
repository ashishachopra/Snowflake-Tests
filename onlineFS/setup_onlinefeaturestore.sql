-- ============================================================================
-- Snowflake Setup Script for Online Feature Store Demo
-- ============================================================================

USE ROLE ACCOUNTADMIN;

SET USERNAME = (SELECT CURRENT_USER());
SELECT $USERNAME;

-- Set query tag for tracking
ALTER SESSION SET QUERY_TAG = '{"origin":"sf_sit-is", "name":"sfguide_intro_to_online_feature_store", "version":{"major":1, "minor":0}, "attributes":{"is_quickstart":1, "source":"sql"}}';

-- ============================================================================
-- SECTION 1: CREATE ROLE AND GRANT ACCOUNT-LEVEL PERMISSIONS
-- ============================================================================

-- Create role for Feature Store operations and grant to current user
CREATE OR REPLACE ROLE FS_DEMO_ROLE;
GRANT ROLE FS_DEMO_ROLE TO USER identifier($USERNAME);

-- Grant account-level permissions
GRANT CREATE DATABASE ON ACCOUNT TO ROLE FS_DEMO_ROLE;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE FS_DEMO_ROLE;
GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE FS_DEMO_ROLE;
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE FS_DEMO_ROLE;
GRANT IMPORT SHARE ON ACCOUNT TO ROLE FS_DEMO_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE FS_DEMO_ROLE;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE FS_DEMO_ROLE;

-- ============================================================================
-- SECTION 2: SWITCH TO ROLE AND CREATE RESOURCES
-- ============================================================================

USE ROLE FS_DEMO_ROLE;

-- Create warehouse
CREATE OR REPLACE WAREHOUSE FS_DEMO_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Warehouse for Feature Store demo';

-- Create database and schema
CREATE OR REPLACE DATABASE FEATURE_STORE_DEMO
    COMMENT = 'Database for Feature Store with taxi trip prediction';

CREATE OR REPLACE SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES
    COMMENT = 'Schema for taxi features and online feature store';

-- Use the created resources
USE WAREHOUSE FS_DEMO_WH;
USE DATABASE FEATURE_STORE_DEMO;
USE SCHEMA TAXI_FEATURES;

-- Create stage for model assets with directory enabled
CREATE OR REPLACE STAGE FS_DEMO_ASSETS
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Stage for storing model assets and data files';

-- Grant full privileges on database and schema to the role
GRANT ALL PRIVILEGES ON DATABASE FEATURE_STORE_DEMO TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON WAREHOUSE FS_DEMO_WH TO ROLE FS_DEMO_ROLE;

-- Grant future privileges to handle dynamically created objects
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON FUTURE DYNAMIC TABLES IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON FUTURE STAGES IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON FUTURE FUNCTIONS IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON FUTURE IMAGE REPOSITORIES IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;
GRANT ALL PRIVILEGES ON FUTURE SERVICES IN SCHEMA FEATURE_STORE_DEMO.TAXI_FEATURES TO ROLE FS_DEMO_ROLE;

-- ============================================================================
-- SECTION 3: NETWORK RULES AND EXTERNAL ACCESS FOR NOTEBOOKS
-- ============================================================================

-- Create network rule to allow all external access (required for notebooks)
CREATE OR REPLACE NETWORK RULE ALLOW_ALL_RULE
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = ('0.0.0.0:443', '0.0.0.0:80');

-- Switch back to ACCOUNTADMIN to create integration
USE ROLE ACCOUNTADMIN;

-- Create external access integration (requires ACCOUNTADMIN)
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION ALLOW_ALL_INTEGRATION
    ALLOWED_NETWORK_RULES = (FEATURE_STORE_DEMO.TAXI_FEATURES.ALLOW_ALL_RULE)
    ENABLED = TRUE;

-- Grant usage on the external access integration to FS_DEMO_ROLE
GRANT USAGE ON INTEGRATION ALLOW_ALL_INTEGRATION TO ROLE FS_DEMO_ROLE;

-- Switch back to FS_DEMO_ROLE
USE ROLE FS_DEMO_ROLE;

-- ============================================================================
-- SECTION 4: COMPUTE POOL FOR MODEL DEPLOYMENT
-- ============================================================================

-- Create compute pool for SPCS model serving
CREATE COMPUTE POOL IF NOT EXISTS trip_eta_prediction_pool
    MIN_NODES = 3
    MAX_NODES = 3
    INSTANCE_FAMILY = 'CPU_X64_L'
    AUTO_RESUME = TRUE
    COMMENT = 'Compute pool for taxi ETA prediction service';

-- Grant usage on compute pool
GRANT USAGE ON COMPUTE POOL trip_eta_prediction_pool TO ROLE FS_DEMO_ROLE;
GRANT OPERATE ON COMPUTE POOL trip_eta_prediction_pool TO ROLE FS_DEMO_ROLE;

-- ============================================================================
-- SETUP COMPLETE
-- ============================================================================
