# Plowshare Rockfile.eu module
# Copyright (c) 2015 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_ROCKFILE_EU_REGEXP_URL='https\?://\(www\.\)\?rockfile\.eu/'

MODULE_ROCKFILE_EU_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account (mandatory)
DESCRIPTION,d,description,S=DESCRIPTION,Set file description
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_ROCKFILE_EU_UPLOAD_REMOTE_SUPPORT=no

# Static function. Proceed with login
# $1: credentials string
# $2: cookie file
# $3: base url
rockfile_eu_login() {
    local AUTH=$1
    local COOKIE_FILE=$2
    local BASE_URL=$3

    local LOGIN_DATA LOGIN_RESULT NAME ERR

    LOGIN_DATA='op=login&redirect=&login=$USER&password=$PASSWORD'
    LOGIN_RESULT=$(post_login "$AUTH" "$COOKIE_FILE" "$LOGIN_DATA" "$BASE_URL") || return

    # Set-Cookie: login xfss
    NAME=$(parse_cookie_quiet 'login' < "$COOKIE_FILE")
    if [ -n "$NAME" ]; then
        log_debug "Successfully logged in as $NAME member"
        return 0
    fi

    return $ERR_LOGIN_FAILED
}

# Upload a file to rockfile.eu
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link
rockfile_eu_upload() {
    local -r COOKIE_FILE=$1
    local -r FILE=$2
    local -r DESTFILE=$3
    local -r BASE_URL='https://rockfile.eu'

    local CV PAGE SESS USER_TYPE UPLOAD_ID TAGS_STR
    local FORM_HTML FORM_ACTION FORM_UTYPE FORM_SESS FORM_SRV_TMP FORM_BUTTON
    local FORM_FN FORM_ST FORM_OP

    if CV=$(storage_get 'cookie_file'); then
        echo "$CV" >"$COOKIE_FILE"

        # Check for expired session
        PAGE=$(curl -b "$COOKIE_FILE" -b 'lang=english' "$BASE_URL/account") || return
        if ! match '\("#accountconfig"\|>Used Space Bar<\)' "$PAGE"; then
            log_error 'Expired session, delete cache entry'
            storage_set 'cookie_file'
            echo 1
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (cached): '$SESS'"
    elif [ -n "$AUTH" ]; then
        rockfile_eu_login "$AUTH" "$COOKIE_FILE" "$BASE_URL" -b 'lang=english' || return
        storage_set 'cookie_file' "$(cat "$COOKIE_FILE")"

        SESS=$(parse_cookie 'xfss' < "$COOKIE_FILE")
        log_debug "session (new): '$SESS'"
    else
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    PAGE=$(curl -b "$COOKIE_FILE" "$BASE_URL/upload_files") || return
    FORM_HTML=$(grep_form_by_name "$PAGE" 'file') || return
    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_UTYPE=$(parse_form_input_by_name 'upload_type' <<< "$PAGE") || return
    FORM_SESS=$(parse_form_input_by_name_quiet 'sess_id' <<< "$PAGE")
    FORM_SRV_TMP=$(parse_form_input_by_name 'srv_tmp_url' <<< "$PAGE") || return
    FORM_BUTTON=$(parse_form_input_by_name 'submit_btn' <<< "$PAGE") || return

    # "reg"
    USER_TYPE=$(parse 'var utype' "='\([^']*\)" <<< "$PAGE") || return
    log_debug "User type: '$USER_TYPE'"

    UPLOAD_ID=$(random dec 12) || return
    PAGE=$(curl_with_log \
        -F "upload_type=$FORM_UTYPE" \
        -F "sess_id=$FORM_SESS" \
        -F "srv_tmp_url=$FORM_TMP_SRV" \
        -F "file_0=@$FILE;filename=$DESTFILE" \
        --form-string "file_0_descr=$DESCRIPTION" \
        --form-string "link_rcpt=$TOEMAIL" \
        --form-string "link_pass=$LINK_PASSWORD" \
        --form-string 'to_folder=' \
        --form-string "submit_btn=$FORM_BUTTON" \
        "${FORM_ACTION}${UPLOAD_ID}&utype=${USER_TYPE}&js_on=1&upload_type=${FORM_UTYPE}" | break_html_lines) || return

    FORM_ACTION=$(parse_form_action <<< "$PAGE") || return
    FORM_FN=$(parse_tag "name='fn'" textarea <<< "$PAGE") || return
    FORM_ST=$(parse_tag "name='st'" textarea <<< "$PAGE") || return
    FORM_OP=$(parse_tag "name='op'" textarea <<< "$PAGE") || return

    if [ "$FORM_ST" = 'OK' ]; then
        PAGE=$(curl \
            -d "fn=$FORM_FN" -d "st=$FORM_ST" -d "op=$FORM_OP" \
            "$FORM_ACTION") || return

        parse '>Download Link<' '">\(.*\)$' 1 <<< "$PAGE" || return
        parse '>Delete Link<' '">\(.*\)$' 1 <<< "$PAGE" || return
        return 0
    fi

    log_error "Unexpected status: $FORM_ST"
    return $ERR_FATAL
}
