*&---------------------------------------------------------------------*
*& Report ZTR_LANDSCAPE_STATUS
*&---------------------------------------------------------------------*
*& Run in the DEVELOPMENT system.
*& Selects transport requests (E070) by owner / date / status and reads
*& the transport cofile (same info as STMS import history) to show
*& whether each request has been imported into the follow-on systems
*& (e.g. QAS and PRD) - with return code, import date and an analysis.
*&
*& Prerequisite: the DEV system can read the transport directory
*& (/usr/sap/trans) shared with the target systems - standard setup.
*&---------------------------------------------------------------------*
REPORT ztr_landscape_status.

TABLES e070.

*----------------------------------------------------------------------*
* Selection screen
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE TEXT-b01.
  SELECT-OPTIONS: s_trkorr FOR e070-trkorr,
                  s_user   FOR e070-as4user DEFAULT sy-uname,
                  s_date   FOR e070-as4date,          " creation date
                  s_func   FOR e070-trfunction.
  PARAMETERS      p_task AS CHECKBOX DEFAULT abap_true. " also requests where user owns a task
SELECTION-SCREEN END OF BLOCK b01.

SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE TEXT-b02.
  PARAMETERS: p_all  RADIOBUTTON GROUP st DEFAULT 'X',  " all requests
              p_open RADIOBUTTON GROUP st,              " open (modifiable) only
              p_rel  RADIOBUTTON GROUP st.              " released only
SELECTION-SCREEN END OF BLOCK b02.

SELECTION-SCREEN BEGIN OF BLOCK b03 WITH FRAME TITLE TEXT-b03.
  PARAMETERS: p_sys1 TYPE sysysid DEFAULT 'QAS' OBLIGATORY,  " 1st target (quality)
              p_sys2 TYPE sysysid DEFAULT 'PRD',             " 2nd target (production)
              p_sys3 TYPE sysysid,                           " optional 3rd target
              p_miss AS CHECKBOX.                            " only not fully imported
SELECTION-SCREEN END OF BLOCK b03.

*----------------------------------------------------------------------*
* Report class
*----------------------------------------------------------------------*
CLASS lcl_report DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES: BEGIN OF ty_out,
             overall    TYPE icon_d,
             trkorr     TYPE e070-trkorr,
             as4text    TYPE e07t-as4text,
             trfunction TYPE e070-trfunction,
             trstatus   TYPE e070-trstatus,
             as4user    TYPE e070-as4user,
             crdate     TYPE e070-as4date,   " created
             chdate     TYPE e070-as4date,   " last changed / released
             s1_icon    TYPE icon_d,
             s1_rc      TYPE char4,
             s1_date    TYPE d,
             s2_icon    TYPE icon_d,
             s2_rc      TYPE char4,
             s2_date    TYPE d,
             s3_icon    TYPE icon_d,
             s3_rc      TYPE char4,
             s3_date    TYPE d,
             analysis   TYPE char80,
           END OF ty_out,
           tt_out TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY.

    METHODS run.

  PRIVATE SECTION.
    TYPES: BEGIN OF ty_req,
             trkorr     TYPE e070-trkorr,
             trfunction TYPE e070-trfunction,
             trstatus   TYPE e070-trstatus,
             as4user    TYPE e070-as4user,
             as4date    TYPE e070-as4date,
           END OF ty_req,
           tt_req TYPE STANDARD TABLE OF ty_req WITH EMPTY KEY.

    TYPES: BEGIN OF ty_sys_status,
             sysid    TYPE sysysid,
             imported TYPE abap_bool,
             rc       TYPE i,
             date     TYPE d,
           END OF ty_sys_status,
           tt_sys_status TYPE STANDARD TABLE OF ty_sys_status WITH EMPTY KEY.

    DATA: mt_req TYPE tt_req,
          mt_out TYPE tt_out,
          mo_alv TYPE REF TO cl_salv_table.

    METHODS select_requests.
    METHODS build_output.
    METHODS read_cofile
      IMPORTING iv_trkorr        TYPE e070-trkorr
      RETURNING VALUE(rs_cofile) TYPE ctslg_cofile.
    METHODS get_sys_status
      IMPORTING is_cofile        TYPE ctslg_cofile
                iv_sysid         TYPE sysysid
      RETURNING VALUE(rs_status) TYPE ty_sys_status.
    METHODS fill_sys_cols
      IMPORTING is_status TYPE ty_sys_status
                iv_rel    TYPE abap_bool
      EXPORTING ev_icon   TYPE icon_d
                ev_rc     TYPE char4
                ev_date   TYPE d.
    METHODS analyse
      IMPORTING it_status TYPE tt_sys_status
                iv_rel    TYPE abap_bool
      CHANGING  cs_out    TYPE ty_out.
    METHODS display.
    METHODS set_col_text
      IMPORTING io_cols TYPE REF TO cl_salv_columns_table
                iv_col  TYPE lvc_fname
                iv_text TYPE csequence
                iv_hide TYPE abap_bool DEFAULT abap_false.
    METHODS on_link_click FOR EVENT link_click OF cl_salv_events_table
      IMPORTING row column.
ENDCLASS.

CLASS lcl_report IMPLEMENTATION.

  METHOD run.
    select_requests( ).
    IF mt_req IS INITIAL.
      MESSAGE 'No transport requests found for the selection' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.
    build_output( ).
    IF mt_out IS INITIAL.
      MESSAGE 'No transport requests match the selection' TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.
    display( ).
  ENDMETHOD.

  METHOD select_requests.
    " Requests (not tasks) owned by the selected users
    SELECT trkorr, trfunction, trstatus, as4user, as4date
      FROM e070
      WHERE trkorr     IN @s_trkorr
        AND as4user    IN @s_user
        AND trfunction IN @s_func
        AND strkorr    = @space
      INTO TABLE @mt_req.

    " Optionally: requests where the user owns a task
    IF p_task = abap_true AND s_user[] IS NOT INITIAL.
      SELECT DISTINCT r~trkorr, r~trfunction, r~trstatus, r~as4user, r~as4date
        FROM e070 AS r
        INNER JOIN e070 AS t ON t~strkorr = r~trkorr
        WHERE r~trkorr     IN @s_trkorr
          AND r~trfunction IN @s_func
          AND r~strkorr    = @space
          AND t~as4user    IN @s_user
        APPENDING TABLE @mt_req.
    ENDIF.

    SORT mt_req BY trkorr.
    DELETE ADJACENT DUPLICATES FROM mt_req COMPARING trkorr.

    " Status filter
    "  D = modifiable, L = modifiable/protected, O = release started
    "  R = released,   N = released (import protection for repaired objects)
    CASE abap_true.
      WHEN p_open.
        DELETE mt_req WHERE trstatus <> 'D' AND trstatus <> 'L' AND trstatus <> 'O'.
      WHEN p_rel.
        DELETE mt_req WHERE trstatus <> 'R' AND trstatus <> 'N'.
    ENDCASE.
  ENDMETHOD.

  METHOD build_output.
    DATA lt_create TYPE SORTED TABLE OF e070create WITH UNIQUE KEY trkorr.
    DATA lt_text   TYPE SORTED TABLE OF e07t WITH NON-UNIQUE KEY trkorr.

    " Creation date (E070-AS4DATE is the last change / release date)
    SELECT * FROM e070create
      FOR ALL ENTRIES IN @mt_req
      WHERE trkorr = @mt_req-trkorr
      INTO TABLE @lt_create.

    SELECT * FROM e07t
      FOR ALL ENTRIES IN @mt_req
      WHERE trkorr = @mt_req-trkorr
      INTO TABLE @lt_text.

    LOOP AT mt_req INTO DATA(ls_req).
      DATA(ls_out) = VALUE ty_out( trkorr     = ls_req-trkorr
                                   trfunction = ls_req-trfunction
                                   trstatus   = ls_req-trstatus
                                   as4user    = ls_req-as4user
                                   chdate     = ls_req-as4date ).

      " Creation date - fall back to last change date if not logged
      ls_out-crdate = VALUE #( lt_create[ trkorr = ls_req-trkorr ]-as4date
                               DEFAULT ls_req-as4date ).
      IF ls_out-crdate NOT IN s_date.
        CONTINUE.
      ENDIF.

      " Description: logon language first, otherwise any language
      READ TABLE lt_text INTO DATA(ls_text)
           WITH KEY trkorr = ls_req-trkorr langu = sy-langu.
      IF sy-subrc <> 0.
        READ TABLE lt_text INTO ls_text WITH KEY trkorr = ls_req-trkorr.
      ENDIF.
      IF sy-subrc = 0.
        ls_out-as4text = ls_text-as4text.
      ENDIF.
      CLEAR ls_text.

      DATA(lv_rel) = xsdbool( ls_req-trstatus = 'R' OR ls_req-trstatus = 'N' ).

      " Import status per target system (only released requests have a cofile)
      DATA(ls_cofile) = COND ctslg_cofile( WHEN lv_rel = abap_true
                                           THEN read_cofile( ls_req-trkorr ) ).

      DATA(lt_status) = VALUE tt_sys_status(
        ( get_sys_status( is_cofile = ls_cofile iv_sysid = p_sys1 ) )
        ( get_sys_status( is_cofile = ls_cofile iv_sysid = p_sys2 ) )
        ( get_sys_status( is_cofile = ls_cofile iv_sysid = p_sys3 ) ) ).

      fill_sys_cols( EXPORTING is_status = lt_status[ 1 ] iv_rel = lv_rel
                     IMPORTING ev_icon = ls_out-s1_icon ev_rc = ls_out-s1_rc ev_date = ls_out-s1_date ).
      fill_sys_cols( EXPORTING is_status = lt_status[ 2 ] iv_rel = lv_rel
                     IMPORTING ev_icon = ls_out-s2_icon ev_rc = ls_out-s2_rc ev_date = ls_out-s2_date ).
      fill_sys_cols( EXPORTING is_status = lt_status[ 3 ] iv_rel = lv_rel
                     IMPORTING ev_icon = ls_out-s3_icon ev_rc = ls_out-s3_rc ev_date = ls_out-s3_date ).

      DELETE lt_status WHERE sysid IS INITIAL.
      analyse( EXPORTING it_status = lt_status iv_rel = lv_rel
               CHANGING  cs_out    = ls_out ).

      IF p_miss = abap_true AND ls_out-overall = icon_green_light.
        CONTINUE.
      ENDIF.

      APPEND ls_out TO mt_out.
    ENDLOOP.

    SORT mt_out BY crdate DESCENDING trkorr DESCENDING.
  ENDMETHOD.

  METHOD read_cofile.
    " Reads the cofile from the transport directory (= STMS import history)
    CALL FUNCTION 'TR_READ_GLOBAL_INFO_OF_REQUEST'
      EXPORTING
        iv_trkorr    = iv_trkorr
        iv_dir_type  = 'T'
        iv_translate = abap_true
      IMPORTING
        es_cofile    = rs_cofile.
  ENDMETHOD.

  METHOD get_sys_status.
    rs_status-sysid = iv_sysid.
    CHECK iv_sysid IS NOT INITIAL.

    READ TABLE is_cofile-systems INTO DATA(ls_system) WITH KEY systemid = iv_sysid.
    CHECK sy-subrc = 0.

    LOOP AT ls_system-steps INTO DATA(ls_step).
      " Ignore export (E) and test import (T) - only real import steps count
      IF ls_step-stepid = 'E' OR ls_step-stepid = 'T'.
        CONTINUE.
      ENDIF.
      rs_status-imported = abap_true.
      rs_status-rc = nmax( val1 = rs_status-rc val2 = CONV i( ls_step-rc ) ).

      LOOP AT ls_step-actions INTO DATA(ls_action).
        rs_status-rc = nmax( val1 = rs_status-rc val2 = CONV i( ls_action-rc ) ).
        IF ls_action-date > rs_status-date.
          rs_status-date = ls_action-date.
        ENDIF.
      ENDLOOP.
    ENDLOOP.
  ENDMETHOD.

  METHOD fill_sys_cols.
    CLEAR: ev_icon, ev_rc, ev_date.
    CHECK is_status-sysid IS NOT INITIAL AND iv_rel = abap_true.

    IF is_status-imported = abap_false.
      ev_icon = icon_light_out.                 " not imported
      RETURN.
    ENDIF.

    ev_rc   = |{ is_status-rc }|.
    ev_date = is_status-date.
    ev_icon = COND #( WHEN is_status-rc = 0 THEN icon_green_light
                      WHEN is_status-rc = 4 THEN icon_yellow_light
                      ELSE                       icon_red_light ).
  ENDMETHOD.

  METHOD analyse.
    DATA lv_first_missing TYPE sysysid.

    IF iv_rel = abap_false.
      cs_out-overall  = icon_light_out.
      cs_out-analysis = 'Open - not released yet'.
      RETURN.
    ENDIF.

    LOOP AT it_status INTO DATA(ls_status).
      IF ls_status-imported = abap_true AND ls_status-rc >= 8.
        cs_out-overall  = icon_red_light.
        cs_out-analysis = |Import error (RC { ls_status-rc }) in { ls_status-sysid }|.
        RETURN.
      ENDIF.

      IF ls_status-imported = abap_false AND lv_first_missing IS INITIAL.
        lv_first_missing = ls_status-sysid.
      ELSEIF ls_status-imported = abap_true AND lv_first_missing IS NOT INITIAL.
        cs_out-overall  = icon_red_light.
        cs_out-analysis = |Imported to { ls_status-sysid } but NOT to { lv_first_missing } (sequence!)|.
        RETURN.
      ENDIF.
    ENDLOOP.

    IF lv_first_missing IS INITIAL.
      cs_out-overall  = icon_green_light.
      cs_out-analysis = 'Imported to all target systems'.
    ELSE.
      cs_out-overall  = icon_yellow_light.
      cs_out-analysis = |Released - waiting for import to { lv_first_missing }|.
    ENDIF.
  ENDMETHOD.

  METHOD display.
    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = mo_alv
                                CHANGING  t_table      = mt_out ).
      CATCH cx_salv_msg INTO DATA(lx_salv).
        MESSAGE lx_salv TYPE 'S' DISPLAY LIKE 'E'.
        RETURN.
    ENDTRY.

    mo_alv->get_functions( )->set_all( abap_true ).
    mo_alv->get_display_settings( )->set_striped_pattern( abap_true ).
    mo_alv->get_display_settings( )->set_list_header(
      |Transport status in landscape ({ lines( mt_out ) } requests)| ).

    DATA(lo_cols) = mo_alv->get_columns( ).
    lo_cols->set_optimize( abap_true ).

    set_col_text( io_cols = lo_cols iv_col = 'OVERALL'  iv_text = 'Status' ).
    set_col_text( io_cols = lo_cols iv_col = 'CRDATE'   iv_text = 'Created on' ).
    set_col_text( io_cols = lo_cols iv_col = 'CHDATE'   iv_text = 'Changed/Released' ).
    set_col_text( io_cols = lo_cols iv_col = 'ANALYSIS' iv_text = 'Analysis' ).

    " Target system columns - headers use the system IDs, hidden if not used
    DATA(lt_sys) = VALUE string_table( ( CONV #( p_sys1 ) ) ( CONV #( p_sys2 ) ) ( CONV #( p_sys3 ) ) ).
    LOOP AT lt_sys INTO DATA(lv_sys).
      DATA(lv_prefix) = |S{ sy-tabix }_|.
      DATA(lv_hide)   = xsdbool( lv_sys IS INITIAL ).
      set_col_text( io_cols = lo_cols iv_col = |{ lv_prefix }ICON| iv_text = |{ lv_sys }|      iv_hide = lv_hide ).
      set_col_text( io_cols = lo_cols iv_col = |{ lv_prefix }RC|   iv_text = |{ lv_sys } RC|   iv_hide = lv_hide ).
      set_col_text( io_cols = lo_cols iv_col = |{ lv_prefix }DATE| iv_text = |{ lv_sys } date| iv_hide = lv_hide ).
    ENDLOOP.

    " Click on request number -> display request (SE09)
    TRY.
        CAST cl_salv_column_table( lo_cols->get_column( 'TRKORR' ) )->set_cell_type( if_salv_c_cell_type=>hotspot ).
      CATCH cx_salv_not_found.
    ENDTRY.
    SET HANDLER on_link_click FOR mo_alv->get_event( ).

    mo_alv->display( ).
  ENDMETHOD.

  METHOD set_col_text.
    TRY.
        DATA(lo_col) = io_cols->get_column( iv_col ).
        lo_col->set_short_text( CONV #( iv_text ) ).
        lo_col->set_medium_text( CONV #( iv_text ) ).
        lo_col->set_long_text( CONV #( iv_text ) ).
        IF iv_hide = abap_true.
          lo_col->set_technical( abap_true ).
        ENDIF.
      CATCH cx_salv_not_found.
    ENDTRY.
  ENDMETHOD.

  METHOD on_link_click.
    READ TABLE mt_out INTO DATA(ls_out) INDEX row.
    CHECK sy-subrc = 0.
    CALL FUNCTION 'TR_DISPLAY_REQUEST'
      EXPORTING
        i_trkorr = ls_out-trkorr.
  ENDMETHOD.

ENDCLASS.

*----------------------------------------------------------------------*
* Events
*----------------------------------------------------------------------*
INITIALIZATION.
  " Default: workbench (K), customizing (W), transport of copies (T)
  s_func[] = VALUE #( sign = 'I' option = 'EQ' ( low = 'K' ) ( low = 'W' ) ( low = 'T' ) ).

START-OF-SELECTION.
  NEW lcl_report( )->run( ).
