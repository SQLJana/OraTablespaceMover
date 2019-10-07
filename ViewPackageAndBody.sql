--Refer: https://sqljana.wordpress.com/2017/01/06/oracle-move-tables-to-another-tablespace-in-parallel-using-dbms_scheduler/#comment-15369

CREATE OR REPLACE VIEW OBJECTS_TO_MOVE_VIEW
AS
WITH everything
AS
(
    --IMPORTANT: Even as a DBA, you may need these privs to select from system views inside a view definition
    --GRANT SELECT ANY DICTIONARY TO RUN_USER;
    --GRANT SELECT ANY TABLE TO RUN_USER;
    ----------
    --Tables
    ----------
    SELECT
        'T_' || owner || '_' || table_name AS name,
        'TABLE' AS object_type, owner, table_name AS object_name, tablespace_name AS current_tablespace_name
      FROM dba_tables
     WHERE
        owner NOT IN ('SYS','SYSTEM','OUTLN','DBSNMP','XDB','APPQOSSYS')
       AND tablespace_name IS NOT NULL
    --
    UNION ALL
    --
    ----------
    --Indexes
    ----------
    SELECT
        'I_' || owner || '_' || index_name AS name,
        'INDEX' AS object_type, owner, index_name as object_name, tablespace_name AS current_tablespace_name
      FROM dba_indexes
     WHERE
        owner NOT IN ('SYS','SYSTEM','OUTLN','DBSNMP','XDB','APPQOSSYS')
       AND tablespace_name IS NOT NULL
       AND index_type NOT LIKE 'IOT%'
    --
    UNION ALL
    --
    ----------
    --IOT's
    ----------
    SELECT
        'O_' || owner || '_' || index_name AS name,
        'IOT' AS object_type, owner, index_name as object_name, tablespace_name AS current_tablespace_name
      FROM dba_indexes
     WHERE
        owner NOT IN ('SYS','SYSTEM','OUTLN','DBSNMP','XDB','APPQOSSYS')
       AND tablespace_name IS NOT NULL
       AND index_type LIKE 'IOT%'
    --
    UNION ALL
    --
    ----------
    --LOB's
    ----------
    SELECT
        'L_' || owner || '_' || table_name AS name,
        'LOB' AS object_type, owner, table_name AS object_name, tablespace_name AS current_tablespace_name
      FROM dba_lobs
     WHERE
        owner NOT IN ('SYS','SYSTEM','OUTLN','DBSNMP','XDB','APPQOSSYS')
       AND tablespace_name IS NOT NULL
)
SELECT
    a.*,
    '<NEW_TABLESPACE_NAME>' AS new_tablespace_name,
    '/* Command for manual execution if necessary */' || CHR(13) ||
    'BEGIN ' || CHR(13) ||
    '  pkg_TS_Mover.prcMoveObjectToNewTS( ' || CHR(13) ||
    '            p_Object_Type => ''' || object_type || ''', ' || CHR(13) ||
    '            p_Owner => ''' || owner || ''', ' || CHR(13) ||
    '            p_Object_Name => ''' || object_name || ''', ' || CHR(13) ||
    '            p_New_Tablespace => ''' || '<NEW_TABLESPACE_NAME>' || '''); ' || CHR(13) ||
    'END;' AS command,
    --
    --Divide the whole set of data into <X> buckets
    --
    NTILE(4) OVER (ORDER BY object_type, object_name, owner) AS Thread_Number
FROM everything a
--Some condition to exclude tables already in the new tablespace
--      and get ones that are still in the big messy old tablespace!
-- (or another criteria that just gets the tables you want to move)
--WHERE tablespace_name = '<MY_OLD_TABLESPACE_NAME>'



CREATE OR REPLACE PACKAGE pkg_TS_Mover AUTHID DEFINER AS
/******************************************************************************
   NAME:       pkg_TS_Mover
   PURPOSE:
 
   REVISIONS:
   Ver        Date        Author           Description
   ---------  ----------  ---------------  ------------------------------------
   1.0        4/13/2015      Jana       1. Created this package.
 
  Jana Sattainathan [Twitter: @SQLJana] [Blog: sqljana.wordpress.com] - Initial Release
******************************************************************************/
 
PROCEDURE prcMoveTableToNewTS
(
    p_Owner IN VARCHAR2,
    p_Table_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
);
 
PROCEDURE prcMoveIndexToNewTS
(
    p_Owner IN VARCHAR2,
    p_Index_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
);
 
PROCEDURE prcMoveIOTToNewTS
(
    p_Owner IN VARCHAR2,
    p_IOT_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
);
 
PROCEDURE prcMoveLOBToNewTS
(
    p_Owner IN VARCHAR2,
    p_LOB_Table_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
);
 
PROCEDURE prcMoveObjectToNewTS
(
    p_Object_Type IN VARCHAR2,
    p_Owner IN VARCHAR2,
    p_Object_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
);
 
PROCEDURE prcMoveForThreadNumber
(
    p_Thread_Number IN NUMBER
);
 
FUNCTION fncIsApplicationRunning
(
    p_Application_Name IN VARCHAR
)
RETURN VARCHAR2;
 
PROCEDURE prcProcessInParallel
(
    p_Application_Name IN VARCHAR
);
 
END pkg_TS_Mover;
/

CREATE OR REPLACE PACKAGE BODY pkg_TS_Mover AS
/******************************************************************************
   NAME:       pkg_TS_Mover
   PURPOSE:
 
   REFERENCE: https://ksadba.wordpress.com/2009/05/26/tuning-plsql-with-multithreading-dbms_scheduler/
 
   REVISIONS:
   Ver        Date        Author           Description
   ---------  ----------  ---------------  ------------------------------------
   1.0        4/13/2015      Jana       1. Created this package.
 
  Jana Sattainathan [Twitter: @SQLJana] [Blog: sqljana.wordpress.com] - Initial Release
******************************************************************************/
 
    cPackageName                CONSTANT VARCHAR2(40) := 'pkg_TS_Mover.';
 
---------------------------------------------------------------------------------
-- MODIFICATION HISTORY
-- Person      Date      Comments
-- ---------   ------    ----------------------------------------------------------
-- Jana       04/13/2015 Created proc
 
--PURPOSE:  Moves a table to a new tablespace and optionally checks to see if the target tablespace is encrypted
--              Raises error if tables does not exist or if table is already in target tablespace
--
--USAGE:
/*
    BEGIN
        pkg_TS_Mover.prcMoveTableToNewTS(
                 p_Owner => 'JANA',
                 p_Table_Name => 'QUEST_PPCM_ADVISORY',
                 p_New_Tablespace => 'ACTUARIAL_DATA_TAB',  --'USERS'
                 p_Ensure_Encrypted_Target_TS => 'N');
    END;
*/
---------------------------------------------------------------------------------
PROCEDURE prcMoveTableToNewTS
(
    p_Owner IN VARCHAR2,
    p_Table_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
)
    IS
 
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcMoveTableToNewTS: ';
 
        v_Count NUMBER := 0;
 
        --Error Handling
        v_err_cd                        NUMBER;             --Error code SQLCODE
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress
    BEGIN
        -- where are we
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';
 
        -- setup v_errm_generic
        v_errm_generic := 'Parameters:'||
                            ' p_Owner: '||p_Owner||
                            ' p_Table_Name: '||p_Table_Name||
                            ' p_New_Tablespace: '||p_New_Tablespace;
 
        --Check to see if the new tablespace exists
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if new tablespace exists';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_tablespaces
        WHERE tablespace_name = p_New_Tablespace;
 
        IF (v_Count = 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The tablespace : ' || NVL(p_New_Tablespace,'[UNSPECIFIED]') || CHR(13) ||
                                        ' does not exist. Please specify a valid encrypted tablespace name.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Check to see if the new tablespace is encrypted
        ---------------------------------------------------------------------------------
        IF p_Ensure_Encrypted_Target_TS = 'Y' THEN
            v_msg_cur_operation := 'Checking if new tablespace is encrypted';
 
            SELECT COUNT(1)
            INTO v_Count
            FROM dba_tablespaces
            WHERE tablespace_name = p_New_Tablespace
                AND encrypted = 'YES';
 
            IF (v_Count = 0) THEN
                v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
                v_sqlerrm   := v_ProcName || 'The tablespace : ' || p_New_Tablespace || ' is not encrypted. ' || CHR(13) ||
                                                'Please specify a valid encrypted tablespace name.';
                RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
            END IF;
        END IF;
 
        --Check to see if the table exists
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if table exists';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_tables
        WHERE owner = p_Owner
            AND table_name = p_Table_Name;
 
        IF (v_Count = 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The table : ' || p_Owner || '.' || p_Table_Name || ' does not exist! ' || CHR(13) ||
                                            'Please specify a valid table name.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Check to see if the table is already in the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if table is already in the new tablespace';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_tables
        WHERE owner = p_Owner
            AND table_name = p_Table_Name
            AND tablespace_name = p_New_Tablespace;
 
        IF (v_Count > 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The table : ' || p_Owner || '.' || p_Table_Name || ' is already in target tablespace : ' || p_New_Tablespace;
 
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Move the table to the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Move table '|| p_Owner ||'.'|| p_Table_Name || ' the new tablespace '|| p_New_Tablespace;
 
        dbms_output.put_line('Table: '||p_Owner||'.'||p_Table_Name);
        EXECUTE IMMEDIATE 'alter table '|| p_Owner ||'.'|| p_Table_Name ||' move tablespace '|| p_New_Tablespace;
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to move table to new tablespace. ' ||                             
                            CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                            CHR(13) || 'For: ' || v_errm_generic ||                             
                            CHR(13) || SQLERRM;             
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
END prcMoveTableToNewTS; 
--------------------------------------------------------------------------------- 
-- MODIFICATION HISTORY -- Person      Date      Comments 
-- ---------   ------    ---------------------------------------------------------- 
-- Jana       04/13/2015 Created proc 
--PURPOSE:  Moves a index to a new tablespace and optionally checks to see if the target tablespace is encrypted 
--              Raises error if tables does not exist or if index is already in target tablespace 
-- --USAGE: 
/*     BEGIN         pkg_TS_Mover.prcMoveIndexToNewTS(
                  p_Owner => 'JANA',
                 p_Index_Name => 'QUEST_PPCM_ADVISORY_PK',
                 p_New_Tablespace => 'ACTUARIAL_DATA_TAB',  --'USERS'
                 p_Ensure_Encrypted_Target_TS => 'N');
    END;
*/
---------------------------------------------------------------------------------
PROCEDURE prcMoveIndexToNewTS
(
    p_Owner IN VARCHAR2,
    p_Index_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
)
    IS
 
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcMoveIndexToNewTS: ';
 
        v_Count NUMBER := 0;
 
        --Error Handling
        v_err_cd                        NUMBER;             --Error code SQLCODE
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress
    BEGIN
        -- where are we
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';
 
        -- setup v_errm_generic
        v_errm_generic := 'Parameters:'||
                            ' p_Owner: '||p_Owner||
                            ' p_Index_Name: '||p_Index_Name||
                            ' p_New_Tablespace: '||p_New_Tablespace;
 
        --Check to see if the new tablespace exists
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if new tablespace exists';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_tablespaces
        WHERE tablespace_name = p_New_Tablespace;
 
        IF (v_Count = 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The tablespace : ' || NVL(p_New_Tablespace,'[UNSPECIFIED]') || CHR(13) ||
                                        ' does not exist. Please specify a valid encrypted tablespace name.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Check to see if the new tablespace is encrypted
        ---------------------------------------------------------------------------------
        IF p_Ensure_Encrypted_Target_TS = 'Y' THEN
            v_msg_cur_operation := 'Checking if new tablespace is encrypted';
 
            SELECT COUNT(1)
            INTO v_Count
            FROM dba_tablespaces
            WHERE tablespace_name = p_New_Tablespace
                AND encrypted = 'YES';
 
            IF (v_Count = 0) THEN
                v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
                v_sqlerrm   := v_ProcName || 'The tablespace : ' || p_New_Tablespace || ' is not encrypted. ' || CHR(13) ||
                                                'Please specify a valid encrypted tablespace name.';
                RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
            END IF;
        END IF;
 
        --Check to see if the index exists
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if index exists';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_indexes
        WHERE owner = p_Owner
            AND index_name = p_Index_Name
            AND index_type NOT IN ('IOT - TOP','LOB');
 
        IF (v_Count = 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The index : ' || p_Owner || '.' || p_Index_Name || ' does not exist! ' || CHR(13) ||
                                            'Please specify a valid index name.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Check to see if the index is already in the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if index is already in the new tablespace';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_indexes
        WHERE owner = p_Owner
            AND table_name = p_Index_Name
            AND tablespace_name = p_New_Tablespace;
 
        IF (v_Count > 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The index : ' || p_Owner || '.' || p_Index_Name || ' is already in target tablespace : ' || p_New_Tablespace;
 
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Move the index to the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Move index '|| p_Owner ||'.'|| p_Index_Name || ' the new tablespace '|| p_New_Tablespace;
 
        dbms_output.put_line('Index: '||p_Owner||'.'||p_Index_Name);
        EXECUTE IMMEDIATE 'alter index '|| p_Owner ||'.'|| p_Index_Name ||' rebuild tablespace '|| p_New_Tablespace;
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             RAISE;         ELSE             v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to move index to new tablespace. ' ||                             
                        CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                        CHR(13) || 'For: ' || v_errm_generic ||                             
                        CHR(13) || SQLERRM;             
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
    END prcMoveIndexToNewTS; 

--------------------------------------------------------------------------------- 
-- MODIFICATION HISTORY -- Person      Date      Comments 
-- ---------   ------    ---------------------------------------------------------- 
-- Jana       04/13/2015 Created proc 
--PURPOSE:  Moves a IOT to a new tablespace and optionally checks to see if the target tablespace is encrypted 
--              Raises error if tables does not exist or if IOT is already in target tablespace 
-- --USAGE: 
/*     BEGIN         
            pkg_TS_Mover.prcMoveIOTToNewTS(                  
                p_Owner => 'JANA',
                 p_IOT_Name => 'IOT_TEST_TABLE',
                 p_New_Tablespace => 'MORT_INTERMEDIATE_DATA_TAB',  --'MORT_INTERMEDIATE_DATA_TAB'
                 p_Ensure_Encrypted_Target_TS => 'N');
    END;
*/
---------------------------------------------------------------------------------
PROCEDURE prcMoveIOTToNewTS
(
    p_Owner IN VARCHAR2,
    p_IOT_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
)
    IS
 
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcMoveIOTToNewTS: ';
 
        v_Count NUMBER := 0;
 
        --Error Handling
        v_err_cd                        NUMBER;             --Error code SQLCODE
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress
    BEGIN
        -- where are we
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';
 
        -- setup v_errm_generic
        v_errm_generic := 'Parameters:'||
                            ' p_Owner: '||p_Owner||
                            ' p_IOT_Name: '||p_IOT_Name||
                            ' p_New_Tablespace: '||p_New_Tablespace;
 
        --Check to see if the new tablespace exists
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if new tablespace exists';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_tablespaces
        WHERE tablespace_name = p_New_Tablespace;
 
        IF (v_Count = 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The tablespace : ' || NVL(p_New_Tablespace,'[UNSPECIFIED]') || CHR(13) ||
                                        ' does not exist. Please specify a valid encrypted tablespace name.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Check to see if the new tablespace is encrypted
        ---------------------------------------------------------------------------------
        IF p_Ensure_Encrypted_Target_TS = 'Y' THEN
            v_msg_cur_operation := 'Checking if new tablespace is encrypted';
 
            SELECT COUNT(1)
            INTO v_Count
            FROM dba_tablespaces
            WHERE tablespace_name = p_New_Tablespace
                AND encrypted = 'YES';
 
            IF (v_Count = 0) THEN
                v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
                v_sqlerrm   := v_ProcName || 'The tablespace : ' || p_New_Tablespace || ' is not encrypted. ' || CHR(13) ||
                                                'Please specify a valid encrypted tablespace name.';
                RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
            END IF;
        END IF;
 
        --Check to see if the IOT exists
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if IOT exists';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_indexes
        WHERE owner = p_Owner
            AND table_name = p_IOT_Name
            AND index_type LIKE 'IOT%';
 
        IF (v_Count = 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The IOT : ' || p_Owner || '.' || p_IOT_Name || ' does not exist! ' || CHR(13) ||
                                            'Please specify a valid IOT table name.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Check to see if the IOT is already in the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if IOT is already in the new tablespace';
 
        SELECT COUNT(1)
        INTO v_Count
        FROM dba_indexes
        WHERE owner = p_Owner
            AND table_name = p_IOT_Name
            AND tablespace_name = p_New_Tablespace;
 
        IF (v_Count > 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The IOT : ' || p_Owner || '.' || p_IOT_Name || ' is already in target tablespace : ' || p_New_Tablespace;
 
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Move the IOT to the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Move IOT '|| p_Owner ||'.'|| p_IOT_Name || ' to the new tablespace '|| p_New_Tablespace;
 
        dbms_output.put_line('IOT: '||p_Owner||'.'||p_IOT_Name);
        EXECUTE IMMEDIATE 'alter table '|| p_Owner ||'.'|| p_IOT_Name ||' move tablespace '|| p_New_Tablespace; -- || ' overflow tablespace '|| p_New_Tablespace;
        EXECUTE IMMEDIATE 'alter table '|| p_Owner ||'.'|| p_IOT_Name ||' move overflow tablespace '|| p_New_Tablespace;
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to move IOT to new tablespace. ' ||                             
                CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                CHR(13) || 'For: ' || v_errm_generic ||                             
                CHR(13) || SQLERRM;             
            
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
    END prcMoveIOTToNewTS; 
    --------------------------------------------------------------------------------- 
    -- MODIFICATION HISTORY -- Person      Date      Comments 
    -- ---------   ------    ---------------------------------------------------------- 
    -- Jana       04/13/2015 Created proc 
    --PURPOSE:  Moves a LOB to a new tablespace and optionally checks to see if the target tablespace is encrypted 
    --              Raises error if tables does not exist or if LOB is already in target tablespace 
    -- --------------------------------------------------------------------------------- 
    PROCEDURE prcMoveLOBToNewTS (     
        p_Owner IN VARCHAR2,     
        p_LOB_Table_Name IN VARCHAR2,     
        p_New_Tablespace IN VARCHAR2,     
        p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y' )     
    IS         
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcMoveLOBToNewTS: ';         
        v_Count NUMBER := 0;         --Error Handling         
        v_err_cd                        NUMBER;             --Error code SQLCODE         
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM         
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..         
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress     
    BEGIN         -- where are we         
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';         
        -- setup v_errm_generic         
        v_errm_generic := 'Parameters:'||                             
            ' p_Owner: '||p_Owner||                             
            ' p_LOB_Table_Name: '||p_LOB_Table_Name||                             
            ' p_New_Tablespace: '||p_New_Tablespace;         
        --Check to see if the new tablespace exists         
        ---------------------------------------------------------------------------------         
        v_msg_cur_operation := 'Checking if new tablespace exists';         
        
        SELECT COUNT(1)         
        INTO v_Count         
        FROM dba_tablespaces         
        WHERE tablespace_name = p_New_Tablespace;         
        
        IF (v_Count = 0) THEN             
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly             
            v_sqlerrm   := v_ProcName || 'The tablespace : ' || NVL(p_New_Tablespace,'[UNSPECIFIED]') || CHR(13) ||                                         
                            ' does not exist. Please specify a valid encrypted tablespace name.';             
                            
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;         
        
        --Check to see if the new tablespace is encrypted         
        ---------------------------------------------------------------------------------         
        IF p_Ensure_Encrypted_Target_TS = 'Y' THEN             
        
            v_msg_cur_operation := 'Checking if new tablespace is encrypted';             
            
            SELECT COUNT(1)             
            INTO v_Count             
            FROM dba_tablespaces             
            WHERE tablespace_name = p_New_Tablespace                 
                AND encrypted = 'YES';             
            
            IF (v_Count = 0) THEN                 
                v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly                 
                v_sqlerrm   := v_ProcName || 'The tablespace : ' || p_New_Tablespace || ' is not encrypted. ' || CHR(13) ||                                                 
                                'Please specify a valid encrypted tablespace name.';                 
                RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);             
            END IF;         
        END IF;         
        
        --Check to see if the LOB exists         
        ---------------------------------------------------------------------------------         
        v_msg_cur_operation := 'Checking if LOB exists';         
        
        SELECT COUNT(1)         
        INTO v_Count         
        FROM dba_lobs         
        WHERE owner = p_Owner             
            AND table_name = p_LOB_Table_Name;         

        IF (v_Count = 0) THEN             
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly             
            v_sqlerrm   := v_ProcName || 'The LOB table : ' || p_Owner || '.' || p_LOB_Table_Name || ' does not exist! ' || CHR(13) ||                                             
                            'Please specify a valid LOB table name.';             

            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;         
        
        --Check to see if the LOB is already in the new tablespace         
        ---------------------------------------------------------------------------------         
        v_msg_cur_operation := 'Checking if LOB is already in the new tablespace';         
        
        SELECT COUNT(1)         
        INTO v_Count         
        FROM dba_lobs         
        WHERE owner = p_Owner             
            AND table_name = p_LOB_Table_Name             
            AND tablespace_name = p_New_Tablespace;         

        IF (v_Count > 0) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The LOB table : ' || p_Owner || '.' || p_LOB_Table_Name || ' is already in target tablespace : ' || p_New_Tablespace;
 
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Move the LOB to the new tablespace
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Move LOB table '|| p_Owner ||'.'|| p_LOB_Table_Name || ' columns to the new tablespace '|| p_New_Tablespace;
 
        FOR v_LOB IN (SELECT owner,table_name,column_name,tablespace_name,segment_name
                        FROM dba_lobs
                        WHERE owner = p_Owner
                            AND table_name = p_LOB_Table_Name) LOOP
 
            dbms_output.put_line('LOB: '||v_LOB.owner||'.'||v_LOB.table_name||'('||v_LOB.column_name||')');
 
            EXECUTE IMMEDIATE 'alter table '||v_LOB.owner||'.'||v_LOB.table_name||' move LOB('||
                               v_LOB.column_name||') store as '||v_LOB.segment_name||
                               ' (tablespace '|| p_New_Tablespace || ')';
        END LOOP;
 
        EXECUTE IMMEDIATE 'alter table '|| p_Owner ||'.'|| p_LOB_Table_Name ||' move tablespace '|| p_New_Tablespace || ' overflow tablespace '|| p_New_Tablespace;         
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to move LOB to new tablespace. ' ||                             
                CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                CHR(13) || 'For: ' || v_errm_generic ||                             
                CHR(13) || SQLERRM;             RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
    END prcMoveLOBToNewTS; 
--------------------------------------------------------------------------------- 
-- MODIFICATION HISTORY -- Person      Date      Comments 
-- ---------   ------    ---------------------------------------------------------- 
-- Jana       04/13/2015 Created proc 
--PURPOSE:  Moves a Object to a new tablespace and optionally checks to see if the target tablespace is encrypted 
--              Raises error if tables does not exist or if Object is already in target tablespace 
-- -- --USAGE: 
/*     BEGIN         
            pkg_TS_Mover.prcMoveObjectToNewTS(                  
                 p_Object_Type => 'TABLE',
                 p_Owner => 'JANA',
                 p_Object_Name => 'QUEST_PPCM_ADVISORY',
                 p_New_Tablespace => 'ACTUARIAL_DATA_TAB',  --'USERS'
                 p_Ensure_Encrypted_Target_TS => 'N');
    END;
*/
---------------------------------------------------------------------------------
PROCEDURE prcMoveObjectToNewTS
(
    p_Object_Type IN VARCHAR2,
    p_Owner IN VARCHAR2,
    p_Object_Name IN VARCHAR2,
    p_New_Tablespace IN VARCHAR2,
    p_Ensure_Encrypted_Target_TS IN VARCHAR2 DEFAULT 'Y'
)
    IS
 
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcMoveObjectToNewTS: ';
 
        v_Count NUMBER := 0;
 
        --Error Handling
        v_err_cd                        NUMBER;             --Error code SQLCODE
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress
    BEGIN
        -- where are we
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';
 
        -- setup v_errm_generic
        v_errm_generic := 'Parameters:'||
                            ' p_Owner: '||p_Owner||
                            ' p_Object_Name: '||p_Object_Name||
                            ' p_New_Tablespace: '||p_New_Tablespace;
 
        --Make sure the object type is one of the known ones
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Validating object type';
 
        IF (p_Object_Type NOT IN ('TABLE','INDEX','IOT','LOB')) THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The parameter p_Object_Type can only accept one of the following values - "TABLE","INDEX","IOT","LOB"';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Call the appropriate move proc
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Calling appropriate move procedure for object type';
 
        IF (p_Object_Type = 'TABLE') THEN
 
            v_msg_cur_operation := 'Moving table';
 
            pkg_TS_Mover.prcMoveTableToNewTS(
                 p_Owner => p_Owner,
                 p_Table_Name => p_Object_Name,
                 p_New_Tablespace => p_New_Tablespace,
                 p_Ensure_Encrypted_Target_TS => p_Ensure_Encrypted_Target_TS);
        END IF;
 
        IF (p_Object_Type = 'INDEX') THEN
 
            v_msg_cur_operation := 'Moving index';
 
            pkg_TS_Mover.prcMoveIndexToNewTS(
                 p_Owner => p_Owner,
                 p_Index_Name => p_Object_Name,
                 p_New_Tablespace => p_New_Tablespace,
                 p_Ensure_Encrypted_Target_TS => p_Ensure_Encrypted_Target_TS);
        END IF;
 
        IF (p_Object_Type = 'IOT') THEN
 
            v_msg_cur_operation := 'Moving IOT';
 
            pkg_TS_Mover.prcMoveIOTToNewTS(
                 p_Owner => p_Owner,
                 p_IOT_Name => p_Object_Name,
                 p_New_Tablespace => p_New_Tablespace,
                 p_Ensure_Encrypted_Target_TS => p_Ensure_Encrypted_Target_TS);
        END IF;
 
        IF (p_Object_Type = 'LOB') THEN
 
            v_msg_cur_operation := 'Moving LOB';
 
            pkg_TS_Mover.prcMoveLOBToNewTS(
                 p_Owner => p_Owner,
                 p_LOB_Table_Name => p_Object_Name,
                 p_New_Tablespace => p_New_Tablespace,
                 p_Ensure_Encrypted_Target_TS => p_Ensure_Encrypted_Target_TS);
        END IF;
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to move Object to new tablespace. ' ||                             
                        CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                        CHR(13) || 'For: ' || v_errm_generic ||                             
                        CHR(13) || SQLERRM;             
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
    END prcMoveObjectToNewTS; 
    --------------------------------------------------------------------------------- 
    -- MODIFICATION HISTORY 
    -- Person      Date      Comments 
    -- ---------   ------    ---------------------------------------------------------- 
    -- Jana       04/13/2015 Created proc 
    --PURPOSE:  Moves all objects that have not been moved to new tablespace for given thread number 
    -- -- --USAGE: 
    /*     
    BEGIN         
            pkg_TS_Mover.prcMoveForThreadNumber(                  
                p_Thread_Number => 4);
    END;
    */
---------------------------------------------------------------------------------
PROCEDURE prcMoveForThreadNumber
(
    p_Thread_Number IN NUMBER
)
    IS
 
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcMoveForThreadNumber: ';
 
        v_Count NUMBER := 0;
 
        --Error Handling
        v_err_cd                        NUMBER;             --Error code SQLCODE
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress
    BEGIN
        -- where are we
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';
 
        -- setup v_errm_generic
        v_errm_generic := 'Parameters:'||
                            ' p_Thread_Number: '|| TO_CHAR(p_Thread_Number);
 
        --Validate parameter
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Validating parameters';
 
        --Move the objects for current thread
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Move objects for thread ' || TO_CHAR(p_Thread_Number);
 
        FOR v_Objects IN (SELECT *
                        FROM objects_to_move_view
                        WHERE thread_number = p_Thread_Number
                         ) LOOP
 
            dbms_output.put_line('Moving: '||v_Objects.object_type||'-'||v_Objects.owner||'.'||v_Objects.object_name);            
 
            prcMoveObjectToNewTS(
                        p_Object_Type => v_Objects.object_type,
                        p_Owner => v_Objects.owner,
                        p_Object_Name => v_Objects.object_name,
                        p_New_Tablespace => v_Objects.new_tablespace_name,
                        p_Ensure_Encrypted_Target_TS => 'N'
                    );
 
        END LOOP;
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying process thread: ' || TO_CHAR(p_Thread_Number) ||                             
                CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                CHR(13) || 'For: ' || v_errm_generic ||                             
                CHR(13) || SQLERRM;             

            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
    END prcMoveForThreadNumber; 
    
    --------------------------------------------------------------------------------- 
    -- MODIFICATION HISTORY 
    -- Person      Date      Comments 
    -- ---------   ------    ---------------------------------------------------------- 
    -- Jana       04/13/2015 Created proc 
    --PURPOSE: Checks to see if an application is already running 
    --              When processing in parallel, we want an application to run only one instance! 
    -- --------------------------------------------------------------------------------- 
    FUNCTION fncIsApplicationRunning (     
        p_Application_Name IN VARCHAR 
        ) 
        RETURN VARCHAR2     
    AS         
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'fncIsApplicationRunning: ';         
        v_Count NUMBER := 0;         
        --Error Handling         
        v_err_cd                        NUMBER; --Error code SQLCODE         
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM         
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..         
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress     
    BEGIN         
        SELECT COUNT(1)         
        INTO v_Count         
        FROM v$Session         
        WHERE client_info = p_Application_Name;          
        
        RETURN (CASE WHEN v_Count > 0 THEN 'Y' ELSE 'N' END);
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to move Object to new tablespace. ' ||                             
                CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                CHR(13) || 'For: ' || v_errm_generic ||                             
                CHR(13) || SQLERRM;             

            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);         
        END IF;     
    END fncIsApplicationRunning; 
    
    --------------------------------------------------------------------------------- 
    -- MODIFICATION HISTORY 
    -- Person      Date      Comments 
    -- ---------   ------    ---------------------------------------------------------- 
    -- Jana       04/13/2015 Created proc 
    --PURPOSE: Given a view name that has the list of things that need to be processed in parallel, does so with given number of threads 
    --              Need to enhance as necessary to cancel running things 
    -- --USAGE: 
    /*     
    BEGIN         
        pkg_TS_Mover.prcProcessInParallel(                  
            p_Application_Name => 'PKG_TS_MOVER');
    END;
    */
---------------------------------------------------------------------------------
 
PROCEDURE prcProcessInParallel
(
    p_Application_Name IN VARCHAR
)
    IS
 
        v_ProcName VARCHAR2(60) := cPackageName || '.' || 'prcProcessInParallel: ';
 
        v_Count NUMBER := 0;
 
        JOB_DOESNT_EXIST EXCEPTION;
        PRAGMA EXCEPTION_INIT(JOB_DOESNT_EXIST, -27475 );
 
        --Error Handling
        v_err_cd                        NUMBER;             --Error code SQLCODE
        v_sqlerrm                       VARCHAR2(1024);     --Error message SQLERRM
        v_errm_generic                  VARCHAR2(1024);     --Generic error message for this function with param values..
        v_msg_cur_operation             VARCHAR2(1024);     --Holds the message that identifies the specific operation in progress
    BEGIN
        -- where are we
        v_msg_cur_operation := v_ProcName || 'Starting Procedure...';
 
        -- setup v_errm_generic
        v_errm_generic := 'Parameters:'||
                            ' p_Application_Name: '|| p_Application_Name;
 
        --Make sure the application is not already running
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Checking if application is already running';
 
        IF (fncIsApplicationRunning(p_Application_Name => p_Application_Name) = 'Y') THEN
            v_err_cd    := -20100;         --REVISIT : To renumber error numbers properly
            v_sqlerrm   := v_ProcName || 'The application ' || p_Application_Name || ' is already running. Stop it before restarting.';
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
 
        --Register application now
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Registering application';
 
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(CLIENT_INFO => p_Application_Name);
 
        --Drop the jobs from prior runs if this was cancelled abruptly
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Drop jobs from prior runs';
 
        BEGIN
           dbms_scheduler.drop_job(job_name => 'PKG_TS_MOVER_1');
        EXCEPTION WHEN JOB_DOESNT_EXIST THEN
           NULL;
        END;
        BEGIN
           dbms_scheduler.drop_job(job_name => 'PKG_TS_MOVER_2');
        EXCEPTION WHEN JOB_DOESNT_EXIST THEN
           NULL;
        END;
        BEGIN
           dbms_scheduler.drop_job(job_name => 'PKG_TS_MOVER_3');
        EXCEPTION WHEN JOB_DOESNT_EXIST THEN
           NULL;
        END;
        BEGIN
           dbms_scheduler.drop_job(job_name => 'PKG_TS_MOVER_4');
        EXCEPTION WHEN JOB_DOESNT_EXIST THEN
           NULL;
        END;
 
        --Create jobs for this run
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Creating jobs for this run';
 
        dbms_scheduler.create_job(
           --job_name => dbms_scheduler.generate_job_name('PKG_TS_MOVER_1'),
           job_name => 'PKG_TS_MOVER_1',
           job_type => 'PLSQL_BLOCK',
           job_action => 'begin pkg_TS_Mover.prcMoveForThreadNumber(1); end;',
           comments => 'Thread 1 to move tablespaces',
           enabled => true,
           auto_drop => true);
 
        dbms_scheduler.create_job(
           --job_name => dbms_scheduler.generate_job_name('PKG_TS_MOVER_2'),
           job_name => 'PKG_TS_MOVER_2',
           job_type => 'PLSQL_BLOCK',
           job_action => 'begin pkg_TS_Mover.prcMoveForThreadNumber(2); end;',
           comments => 'Thread 2 to move tablespaces',
           enabled => true,
           auto_drop => true);
 
        dbms_scheduler.create_job(
           --job_name => dbms_scheduler.generate_job_name('PKG_TS_MOVER_3'),
           job_name => 'PKG_TS_MOVER_3',
           job_type => 'PLSQL_BLOCK',
           job_action => 'begin pkg_TS_Mover.prcMoveForThreadNumber(3); end;',
           comments => 'Thread 3 to move tablespaces',
           enabled => true,
           auto_drop => true);
 
        dbms_scheduler.create_job(
           --job_name => dbms_scheduler.generate_job_name('PKG_TS_MOVER_4'),
           job_name => 'PKG_TS_MOVER_4',
           job_type => 'PLSQL_BLOCK',
           job_action => 'begin pkg_TS_Mover.prcMoveForThreadNumber(4); end;',
           comments => 'Thread 4 to move tablespaces',
           enabled => true,
           auto_drop => true);
 
        --Wait for all async jobs to complete
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Waiting for jobs to complete';
 
        WHILE (1=1) LOOP
 
            SELECT COUNT(1)
            INTO v_Count
            FROM dba_scheduler_jobs
            WHERE job_name LIKE 'PKG_TS_MOVER_%';
 
            --Bail if there are no more jobs left...
            IF (v_Count = 0) THEN
                EXIT;
            END IF;
 
            DBMS_LOCK.sleep(20);
        END LOOP;                
 
        --Un-Register application now in case it is pooled
        ---------------------------------------------------------------------------------
        v_msg_cur_operation := 'Registering application';
 
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO(CLIENT_INFO => NULL);        
 
    EXCEPTION WHEN OTHERS THEN
        --For Oracle Errors, translate it to our message and raise our errors as is
        IF (SQLCODE >= -20999) AND (SQLCODE <= -20000) THEN             
            RAISE;         
        ELSE             
            v_err_cd := -20205; /*REVISIT: To take care of error numbering*/             
            v_sqlerrm := v_ProcName || 'Error occured when trying to process in parallel. ' ||                             
                        CHR(13) || 'When: ' || v_msg_cur_operation ||                             
                        CHR(13) || 'For: ' || v_errm_generic ||                             
                        CHR(13) || SQLERRM;             

            DBMS_APPLICATION_INFO.SET_CLIENT_INFO(CLIENT_INFO => NULL);
 
            RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
        END IF;
    END prcProcessInParallel;
 
END pkg_TS_Mover;
/
 
