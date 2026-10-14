#!/bin/sh
# Claude Code runs this as its browser ($BROWSER) while Sidelight signs a Claude account in. Rather than open a
# browser, it hands the sign-in link to Sidelight, which lets you open it in the browser you choose or copy it.
umask 077
printf '%s' "$1" >"$SIDELIGHT_SIGN_IN_LINK.$$" && mv -f "$SIDELIGHT_SIGN_IN_LINK.$$" "$SIDELIGHT_SIGN_IN_LINK"
