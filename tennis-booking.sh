#!/bin/bash
# tennis-booking.sh — Tennis court availability & booking for ep-3 systems
# Works with: TC Kleinberghofen & TC Erdweg
# Requires: curl, jq or grep/sed (jq optional)
#
# Usage:
#   tennis.sh check [kleinberghofen|erdweg] [YYYY-MM-DD]
#   tennis.sh details [kleinberghofen|erdweg] YYYY-MM-DD HH:MM COURT
#   tennis.sh book [kleinberghofen|erdweg] YYYY-MM-DD HH:MM COURT
#   tennis.sh cancel [kleinberghofen|erdweg] BOOKING_ID
#
# Environment variables:
#   TENNIS_KB_EMAIL, TENNIS_KB_PASS  — Kleinberghofen credentials
#   TENNIS_ER_EMAIL, TENNIS_ER_PASS  — Erdweg credentials

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────

declare -A SITES
SITES[kleinberghofen]="https://buchen.tc-kleinberghofen.de"
SITES[erdweg]="https://tennis-erdweg-online.de"

declare -A COURTS
COURTS[kleinberghofen]="1 2"
COURTS[erdweg]="4 5 6 7 8 9"

declare -A COURT_DISPLAY
COURT_DISPLAY[kleinberghofen]="1:1 2:2"
COURT_DISPLAY[erdweg]="4:1 5:2 6:3 7:4 8:5 9:6"

declare -A HOURS
HOURS[kleinberghofen]="06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21"
HOURS[erdweg]="08 09 10 11 12 13 14 15 16 17 18 19 20"

COOKIE_DIR="/tmp/tennis-cookies"
mkdir -p "$COOKIE_DIR"

JQ="/home/node/.openclaw/bin/jq"
[ ! -x "$JQ" ] && JQ="jq"

# ─── Helpers ─────────────────────────────────────────────────────

get_creds() {
    local site="$1"
    case "$site" in
        kleinberghofen)
            echo "${TENNIS_KB_EMAIL:-}" "${TENNIS_KB_PASS:-}"
            ;;
        erdweg)
            echo "${TENNIS_ER_EMAIL:-}" "${TENNIS_ER_PASS:-}"
            ;;
    esac
}

get_display_court() {
    local site="$1" court_id="$2"
    for mapping in ${COURT_DISPLAY[$site]}; do
        local id="${mapping%%:*}"
        local display="${mapping##*:}"
        if [ "$id" = "$court_id" ]; then
            echo "$display"
            return
        fi
    done
    echo "$court_id"
}

get_internal_court() {
    local site="$1" display_num="$2"
    for mapping in ${COURT_DISPLAY[$site]}; do
        local id="${mapping%%:*}"
        local display="${mapping##*:}"
        if [ "$display" = "$display_num" ]; then
            echo "$id"
            return
        fi
    done
    echo "$display_num"
}

# ─── Login ───────────────────────────────────────────────────────

login() {
    local site="$1"
    local base="${SITES[$site]}"
    local creds
    creds=($(get_creds "$site"))
    local email="${creds[0]:-}"
    local pass="${creds[1]:-}"

    if [ -z "$email" ] || [ -z "$pass" ]; then
        echo "ERROR: Credentials not set for $site"
        echo "Set TENNIS_${site^^}_EMAIL and TENNIS_${site^^}_PASS"
        return 1
    fi

    local cookie_file="$COOKIE_DIR/${site}.cookie"

    # Login via POST
    local response
    response=$(curl -s -c "$cookie_file" -b "$cookie_file" \
        -X POST "$base/user/login" \
        -d "lf-email=${email}&lf-pw=${pass}" \
        -w "\n%{http_code}" \
        -L 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # Check if login succeeded (redirects to / or shows user panel)
    if echo "$body" | grep -qi "logout\|abmelden\|mein.konto\|my.account"; then
        echo "OK"
        return 0
    elif [ "$http_code" = "302" ] || [ "$http_code" = "200" ]; then
        # Might still be OK — check cookies
        if [ -s "$cookie_file" ]; then
            echo "OK"
            return 0
        fi
    fi

    echo "FAILED"
    return 1
}

# ─── Check availability (public, no login needed) ───────────────

check_availability() {
    local site="$1"
    local date="${2:-$(date +%Y-%m-%d)}"
    local base="${SITES[$site]}"

    echo "═══════════════════════════════════════════"
    echo "  🎾 $site — $date"
    echo "═══════════════════════════════════════════"

    # Fetch calendar page
    local html
    html=$(curl -s "$base/?date=$date" 2>/dev/null)

    if [ -z "$html" ]; then
        echo "ERROR: Could not reach $base"
        return 1
    fi

    # Parse: extract all slot links and their status
    # Free slots:  class="calendar-cell cc-free"  with href="/square?ds=...&ts=...&te=...&s=..."
    # Booked slots: class="calendar-cell cc-set"   (or just div without link)
    # Past slots:   class="calendar-cell cc-over"

    local target_date="$date"

    # Extract free slots for the target date
    echo ""
    echo "  Plätze: $(echo "${COURTS[$site]}" | wc -w)"
    echo "  Zeitfenster: ${HOURS[$site]// /, }:00 Uhr"
    echo ""

    local found_free=0
    local found_booked=0

    # Parse free slots
    echo "  ✅ FREIE SLOTS:"
    echo "  ─────────────────────────────"
    while IFS= read -r line; do
        if echo "$line" | grep -q "ds=${target_date}.*cc-free"; then
            local ts te s
            ts=$(echo "$line" | grep -oP 'ts=\K[0-9:]+')
            te=$(echo "$line" | grep -oP 'te=\K[0-9:]+')
            s=$(echo "$line" | grep -oP 's=\K[0-9]+')
            local display_court
            display_court=$(get_display_court "$site" "$s")
            echo "  Platz $display_court: $ts - $te"
            found_free=$((found_free + 1))
        fi
    done <<< "$html"

    if [ $found_free -eq 0 ]; then
        echo "  (keine freien Slots)"
    fi

    # Parse booked slots
    echo ""
    echo "  ❌ BELEGTE SLOTS:"
    echo "  ─────────────────────────────"

    # Booked slots have cc-set class or are divs (not links) with text content
    while IFS= read -r line; do
        if echo "$line" | grep -q "ds=${target_date}.*cc-set"; then
            local ts te s
            ts=$(echo "$line" | grep -oP 'ts=\K[0-9:]+')
            te=$(echo "$line" | grep -oP 'te=\K[0-9:]+')
            s=$(echo "$line" | grep -oP 's=\K[0-9]+')
            local display_court
            display_court=$(get_display_court "$site" "$s")

            # Try to extract booker name (sometimes shown in cc-label)
            local name
            name=$(echo "$line" | grep -oP 'cc-label[^>]*>\K[^<]+' | head -1)
            if [ -n "$name" ] && [ "$name" != "Belegt" ]; then
                echo "  Platz $display_court: $ts - $te  ($name)"
            else
                echo "  Platz $display_court: $ts - $te  (belegt)"
            fi
            found_booked=$((found_booked + 1))
        fi
    done <<< "$html"

    if [ $found_booked -eq 0 ]; then
        echo "  (keine belegten Slots)"
    fi

    echo ""
    echo "  Gesamt: $found_free frei, $found_booked belegt"
    echo "═══════════════════════════════════════════"
}

# ─── Slot details (with login for booker names) ─────────────────

slot_details() {
    local site="$1"
    local date="$2"
    local time="$3"
    local court="$4"
    local base="${SITES[$site]}"

    local internal_court
    internal_court=$(get_internal_court "$site" "$court")

    local te_hour
    te_hour=$(printf "%02d" $((10#${time%%:*} + 1)))
    local te="${te_hour}:00"

    local url="$base/square?ds=${date}&ts=${time}&te=${te}&s=${internal_court}"

    # Try with login first (for booker names)
    local cookie_file="$COOKIE_DIR/${site}.cookie"
    local html

    if [ -s "$cookie_file" ]; then
        html=$(curl -s -b "$cookie_file" "$url" 2>/dev/null)
    else
        html=$(curl -s "$url" 2>/dev/null)
    fi

    echo "═══════════════════════════════════════════"
    echo "  🎾 $site — Platz $court"
    echo "  $date, $time - $te Uhr"
    echo "═══════════════════════════════════════════"

    if echo "$html" | grep -qi "bereits belegt\|already booked"; then
        # Try to find booker name
        local booker
        booker=$(echo "$html" | grep -oP '(?:gebucht von|booked by|Reserviert)[^<]*<[^>]*>[^<]*' | head -1)
        if [ -n "$booker" ]; then
            echo "  Status: ❌ Belegt ($booker)"
        else
            echo "  Status: ❌ Belegt"
        fi
    elif echo "$html" | grep -qi "frei\|free\|verfügbar\|available"; then
        echo "  Status: ✅ Frei"
    else
        echo "  Status: ⏳ Vorbei / Unbekannt"
    fi
    echo "═══════════════════════════════════════════"
}

# ─── Book a slot ─────────────────────────────────────────────────

book_slot() {
    local site="$1"
    local date="$2"
    local time="$3"
    local court="$4"
    local base="${SITES[$site]}"

    local internal_court
    internal_court=$(get_internal_court "$site" "$court")

    local te_hour
    te_hour=$(printf "%02d" $((10#${time%%:*} + 1)))
    local te="${te_hour}:00"

    echo "═══════════════════════════════════════════"
    echo "  🎾 Buchung: $site"
    echo "  Platz $court, $date, $time - $te Uhr"
    echo "═══════════════════════════════════════════"

    # Login first
    echo "  → Login..."
    local login_result
    login_result=$(login "$site")
    if [ "$login_result" != "OK" ]; then
        echo "  ❌ Login fehlgeschlagen!"
        return 1
    fi
    echo "  ✅ Login erfolgreich"

    local cookie_file="$COOKIE_DIR/${site}.cookie"

    # Step 1: Open the slot page (get any CSRF tokens)
    local slot_url="$base/square?ds=${date}&ts=${time}&te=${te}&s=${internal_court}"
    echo "  → Prüfe Verfügbarkeit..."

    local slot_page
    slot_page=$(curl -s -b "$cookie_file" -c "$cookie_file" "$slot_url" 2>/dev/null)

    if echo "$slot_page" | grep -qi "bereits belegt\|already booked"; then
        echo "  ❌ Platz ist bereits belegt!"
        return 1
    fi

    if echo "$slot_page" | grep -qi "vorbei\|too late\|past"; then
        echo "  ❌ Zeitfenster liegt in der Vergangenheit!"
        return 1
    fi

    # Step 2: Find the booking form and submit
    # ep-3 typically has a form with action="/booking/..." or uses a POST to /square
    local form_action
    form_action=$(echo "$slot_page" | grep -oP 'action="(/booking[^"]*)"' | head -1 | grep -oP '"/[^"]*"' | tr -d '"')

    if [ -z "$form_action" ]; then
        # Try alternative: direct POST to square endpoint
        form_action="/square"
    fi

    echo "  → Buche Platz..."

    local book_response
    book_response=$(curl -s -b "$cookie_file" -c "$cookie_file" \
        -X POST "$base${form_action}" \
        -d "ds=${date}&ts=${time}&te=${te}&s=${internal_court}&booking=1" \
        -w "\n%{http_code}" \
        -L 2>/dev/null)

    local http_code
    http_code=$(echo "$book_response" | tail -1)
    local body
    body=$(echo "$book_response" | sed '$d')

    if echo "$body" | grep -qi "erfolgreich\|success\|gebucht\|booked\|bestätigung\|confirmation"; then
        echo "  ✅ Platz erfolgreich gebucht!"
        echo ""
        echo "  📋 Details:"
        echo "     Verein:  $site"
        echo "     Platz:   $court"
        echo "     Datum:   $date"
        echo "     Zeit:    $time - $te Uhr"
    elif echo "$body" | grep -qi "fehler\|error\|belegt\|occupied"; then
        echo "  ❌ Buchung fehlgeschlagen!"
        # Try to extract error message
        local error_msg
        error_msg=$(echo "$body" | grep -oP '(?:class="error"|class="red")[^>]*>[^<]*' | head -1 | sed 's/<[^>]*>//g')
        [ -n "$error_msg" ] && echo "  Grund: $error_msg"
    else
        echo "  ⚠️ Buchungsstatus unklar (HTTP $http_code)"
        echo "  Bitte manuell prüfen: $slot_url"
    fi

    echo "═══════════════════════════════════════════"
}

# ─── Main ────────────────────────────────────────────────────────

usage() {
    cat << 'EOF'
🎾 Tennis-Platz Buchungssystem (ep-3)
═════════════════════════════════════

Verfügbarkeit prüfen:
  tennis.sh check kleinberghofen              # Heute
  tennis.sh check kleinberghofen 2026-04-20   # Bestimmtes Datum
  tennis.sh check erdweg                      # TC Erdweg, heute
  tennis.sh check erdweg 2026-04-20           # TC Erdweg, Datum

Slot-Details (wer hat gebucht?):
  tennis.sh details erdweg 2026-04-19 15:00 6

Platz buchen (Login erforderlich):
  tennis.sh book kleinberghofen 2026-04-20 18:00 1
  tennis.sh book erdweg 2026-04-20 18:00 3

Vereine:
  kleinberghofen  — TC Kleinberghofen (2 Plätze, 06-22 Uhr)
  erdweg          — TC Erdweg (6 Plätze, 08-21 Uhr)

Credentials (Env-Vars):
  TENNIS_KB_EMAIL, TENNIS_KB_PASS  — Kleinberghofen
  TENNIS_ER_EMAIL, TENNIS_ER_PASS  — Erdweg
EOF
}

case "${1:-help}" in
    check)
        check_availability "${2:?Verein angeben (kleinberghofen|erdweg)}" "${3:-}"
        ;;
    details)
        slot_details "${2:?Verein}" "${3:?Datum (YYYY-MM-DD)}" "${4:?Uhrzeit (HH:MM)}" "${5:?Platz-Nr}"
        ;;
    book)
        book_slot "${2:?Verein}" "${3:?Datum (YYYY-MM-DD)}" "${4:?Uhrzeit (HH:MM)}" "${5:?Platz-Nr}"
        ;;
    help|--help|-h|*)
        usage
        ;;
esac
