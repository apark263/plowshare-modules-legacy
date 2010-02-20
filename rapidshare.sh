#!/bin/bash
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
#

MODULE_RAPIDSHARE_REGEXP_URL="http://\(\w\+\.\)\?rapidshare\.com/"
MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,Use Premium-Zone account"
MODULE_RAPIDSHARE_UPLOAD_OPTIONS="
AUTH_PREMIUMZONE,a:,auth:,USER:PASSWORD,Use Premium-Zone account
AUTH_FREEZONE,b:,auth-freezone:,USER:PASSWORD,Use Free-Zone account"
MODULE_RAPIDSHARE_DOWNLOAD_CONTINUE=no

# Output a rapidshare file download URL (anonymous and premium)
#
# rapidshare_download RAPIDSHARE_URL
#
# Note to premium users: In your account settings, uncheck option:
# "Direct downloads, requested files are saved without redirection via RapidShare"
# The trick to direct download (not used here) is to append "directstart=1" to URL.
# For example: http://rapidshare.com/files/12345678/foo_bar_file_name?directstart=1
#
rapidshare_download() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_DOWNLOAD_OPTIONS" "$@")"

    URL=$1

    # Try to login if account provided ($AUTH not null)
    # Even if login/passwd are wrong cookie content is returned
    LOGIN_DATA='uselandingpage=1&submit=Premium%20Zone%20Login&login=$USER&password=$PASSWORD'
    COOKIE_DATA=$(post_login "$AUTH" "$LOGIN_DATA" \
            "https://ssl.rapidshare.com/cgi-bin/premiumzone.cgi")
    ccurl() { curl -b <(echo "$COOKIE_DATA") "$@"; }

    while retry_limit_not_reached || return 3; do
        PAGE=$(ccurl "$URL")

        ERR1='file could not be found'
        ERR2='suspected to contain illegal content'
        echo "$PAGE" | grep -q "$ERR1" &&
            { error "file not found"; return 254; }
        echo "$PAGE" | grep -q "$ERR2" &&
            { error "file blocked"; return 254; }

        WAIT_URL=$(echo "$PAGE" | parse '<form' 'action="\([^"]*\)"') ||
            return 1

        test "$CHECK_LINK" && return 255

        if [ -z "$AUTH" ]; then
            DATA=$(ccurl --data "dl.start=Free" "$WAIT_URL")
        else
            DATA=$(ccurl --data "dl.start=PREMIUM" "$WAIT_URL")
            match 'Your Cookie has not been recognized' "$DATA" &&
                { error "login process failed"; return 1; }
        fi
        test -z "$DATA" &&
            { error "can't get wait URL contents"; return 1; }

        match "is already downloading a file" "$DATA" && {
            debug "Your IP is already downloading a file"
            countdown 2 1 minutes 60 || return 2
            continue
        }

        LIMIT=$(echo "$DATA" | parse "minute" \
                "[[:space:]]\([[:digit:]]\+\) minutes[[:space:]]" 2>/dev/null) && {
            debug "No free slots, server asked to wait $LIMIT minutes"
            countdown $LIMIT 1 minutes 60 || return 2
            continue
        }

        FILE_URL=$(echo "$DATA" | parse '<form name="dlf"' 'action="\([^"]*\)"' 2>/dev/null) || {
            debug "No free slots, waiting 2 minutes (default value)"
            countdown 2 1 minutes 60 || return 2
            continue
        }

        break
    done

    if [ -z "$AUTH" ]; then
        SLEEP=$(echo "$DATA" | parse "^var c=" "c=\([[:digit:]]\+\);") || return 1
        countdown $((SLEEP + 1)) 20 seconds 1 || return 2

        echo $FILE_URL
    else
        COOKIE_FILE=$(create_tempfile)
        echo "$COOKIE_DATA" >$COOKIE_FILE

        echo $FILE_URL
        echo
        echo $COOKIE_FILE
    fi

    return 0
}

# Upload a file to Rapidshare (anonymously, Free-Zone or Premium-Zone)
#
# rapidshare_upload [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#   -b USER:PASSWORD, --auth-freezone=USER:PASSWORD
#
rapidshare_upload() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"

    if test -n "$AUTH_PREMIUMZONE"; then
        rapidshare_upload_premiumzone "$@"
    elif test -n "$AUTH_FREEZONE"; then
        rapidshare_upload_freezone "$@"
    else
        rapidshare_upload_anonymous "$@"
    fi
}

# Upload a file to Rapidshare (anonymously) and return LINK_URL (KILL_URL)
#
# rapidshare_upload_anonymous FILE [DESTFILE]
#
rapidshare_upload_anonymous() {
    set -e
    FILE=$1
    DESTFILE=${2:-$FILE}

    UPLOAD_URL="http://www.rapidshare.com"
    debug "downloading upload page: $UPLOAD_URL"

    ACTION=$(curl "$UPLOAD_URL" | parse 'form name="ul"' 'action="\([^"]*\)') || return 1
    debug "upload to: $ACTION"

    INFO=$(curl -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" "$ACTION") || return 1
    URL=$(echo "$INFO" | parse "downloadlink" ">\(.*\)<") || return 1
    KILL=$(echo "$INFO" | parse "loeschlink" ">\(.*\)<")

    echo "$URL ($KILL)"
}

# Upload a file to Rapidshare (Free-Zone) and return LINK_URL
#
# rapidshare_upload_freezone [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -b USER:PASSWORD, --auth-freezone=USER:PASSWORD
#
rapidshare_upload_freezone() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    DESTFILE=${2:-$FILE}

    FREEZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/collectorszone.cgi"
    LOGIN_DATA='username=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH_FREEZONE" "$LOGIN_DATA" "$FREEZONE_LOGIN_URL") ||
        { error "error on login process"; return 1; }
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }

    debug "downloading upload page: $FREEZONE_LOGIN_URL"
    UPLOAD_PAGE=$(ccurl $FREEZONE_LOGIN_URL) || return 1
    ACCOUNTID=$(echo "$UPLOAD_PAGE" | \
        parse 'name="freeaccountid"' 'value="\([[:digit:]]*\)"')
    ACTION=$(echo "$UPLOAD_PAGE" | parse '<form name="ul"' 'action="\([^"]*\)"')
    IFS=":" read USER PASSWORD <<< "$AUTH_FREEZONE"
    debug "uploading file: $FILE"
    UPLOADED_PAGE=$(ccurl \
        -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" \
        -F "freeaccountid=$ACCOUNTID" \
        -F "password=$PASSWORD" \
        -F "mirror=on" $ACTION) || return 1

    debug "download upload page to get url: $FREEZONE_LOGIN_URL"
    UPLOAD_PAGE=$(ccurl $FREEZONE_LOGIN_URL) || return 1
    FILEID=$(echo "$UPLOAD_PAGE" | grep ^Adliste | tail -n1 | \
        parse Adliste 'Adliste\["\([[:digit:]]*\)"')
    MATCH="^Adliste\[\"$FILEID\"\]"
    KILLCODE=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "killcode\"\] = '\(.*\)'") || return 1
    FILENAME=$(echo "$UPLOAD_PAGE" | parse "$MATCH" "filename\"\] = \"\(.*\)\"") || return 1

    # There is a killcode in the HTML, but it's not used to build a URL
    # but as a param in a POST submit, so I assume there is no kill URL for
    # freezone files. Therefore, output just the file URL.
    URL="http://rapidshare.com/files/$FILEID/$FILENAME.html"
    echo "$URL"
}

# Upload a file to Rapidshare (Premium-Zone) and return LINK_URL
#
# rapidshare_upload_premiumzone [OPTIONS] FILE [DESTFILE]
#
# Options:
#   -a USER:PASSWORD, --auth=USER:PASSWORD
#
rapidshare_upload_premiumzone() {
    set -e
    eval "$(process_options rapidshare "$MODULE_RAPIDSHARE_UPLOAD_OPTIONS" "$@")"
    FILE=$1
    DESTFILE=${2:-$FILE}

    PREMIUMZONE_LOGIN_URL="https://ssl.rapidshare.com/cgi-bin/premiumzone.cgi"
    # Even if login/passwd are wrong cookie content is returned
    LOGIN_DATA='uselandingpage=1&submit=Premium%20Zone%20Login&login=$USER&password=$PASSWORD'
    COOKIES=$(post_login "$AUTH_PREMIUMZONE" "$LOGIN_DATA" "$PREMIUMZONE_LOGIN_URL") ||
        { error "error on login process"; return 1; }
    ccurl() { curl -b <(echo "$COOKIES") "$@"; }

    debug "downloading upload page: $PREMIUMZONE_LOGIN_URL"
    UPLOAD_PAGE=$(ccurl $PREMIUMZONE_LOGIN_URL) || return 1

    if test -z "$UPLOAD_PAGE"; then
        error "login process failed"
        return 1
    fi

    # Extract upload form part
    UPLOAD_PAGE=$(echo "$UPLOAD_PAGE" | sed -n '/<form .*name="ul"/,/<\/form>/p')

    local form_url=$(echo "$UPLOAD_PAGE" | parse '<form .*name="ul"' 'action="\([^"]*\)' 2>/dev/null)
    local form_login=$(echo "$UPLOAD_PAGE" | parse '<input\([[:space:]]*[^ ]*\)*name="login"' 'value="\([^"]*\)' 2>/dev/null)
    local form_password=$(echo "$UPLOAD_PAGE" | parse '<input\([[:space:]]*[^ ]*\)*name="password"' 'value="\([^"]*\)' 2>/dev/null)

    debug "uploading file: $FILE"
    UPLOADED_PAGE=$(ccurl \
        -F "login=$form_login" \
        -F "password=$form_password" \
        -F "filecontent=@$FILE;filename=$(basename "$DESTFILE")" \
        -F "mirror=on" \
        -F "u.x=56" -F "u.y=9" "$form_url") || return 1

    debug "download upload page to get url: $PREMIUMZONE_LOGIN_URL"
    UPLOAD_PAGE=$(ccurl $PREMIUMZONE_LOGIN_URL) || return 1
    FILEID=$(echo "$UPLOAD_PAGE" | grep ^Adliste | head -n1 | \
        parse Adliste 'Adliste\["\([[:digit:]]*\)"')
    MATCH="^Adliste\[\"$FILEID\"\]"
    KILLCODE=$(echo "$UPLOAD_PAGE" | parse "$MATCH" 'killcode"\] = "\([^"]*\)') || return 1
    FILENAME=$(echo "$UPLOAD_PAGE" | parse "$MATCH" 'filename"\] = "\([^"]*\)') || return 1

    URL="http://rapidshare.com/files/$FILEID/$FILENAME.html"
    echo "$URL"
}
