# signing.sh: which certificate to sign with. Read by `bundle` and `dmg` with `source`;
# it is not a program of its own.
#
# In order:
#   1. SPACES_SIGN_IDENTITY, when set: the name or fingerprint of a certificate in your
#      keychains ("Developer ID Application: ..." to hand the app to other people), or "-"
#      for no certificate. SPACES_SIGN_KEYCHAIN may name the keychain to look in.
#   2. The certificate that scripts/setup-signing made, in ~/.config/open-spaces/signing
#      (or SPACES_SIGNING_DIR). It has a keychain of its own, so signing asks for
#      nothing and your own keychain is left alone.
#   3. No certificate ("ad hoc"), with a warning: the build runs, but macOS forgets its
#      permissions after the next build, and it does not look for updates.
#
# After `load_signing`:
#   sign_kind      own | developer-id | given | adhoc
#   sign_identity  what codesign is told to sign with
#   sign <codesign options and a path>   signs with the hardened runtime
#   signing_dir    the folder with the keys (it may not exist)

signing_dir="${SPACES_SIGNING_DIR:-$HOME/.config/open-spaces/signing}"
sign_kind=adhoc
sign_identity="-"
sign_options=()

load_signing() {
  local keychain="$signing_dir/signing.keychain-db"
  local password="$signing_dir/signing.keychain.password"
  local given="${SPACES_SIGN_IDENTITY:-}"
  sign_options=(--timestamp=none)

  if [[ "$given" == "-" ]]; then
    sign_kind=adhoc
    sign_identity="-"
  elif [[ -n "$given" ]]; then
    sign_identity="$given"
    sign_kind=given
    # A Developer ID signature needs a time stamp from Apple's server (notarising checks
    # for it). Any other signature does not, and asking for one would need the network.
    # The identity may be given by name or by fingerprint, so the keychain's list is read too.
    if [[ "$given" == "Developer ID "* ]] ||
      security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$given" | grep -q '"Developer ID '; then
      sign_kind=developer-id
      sign_options=(--timestamp)
    fi
    if [[ -n "${SPACES_SIGN_KEYCHAIN:-}" ]]; then
      sign_options+=(--keychain "$SPACES_SIGN_KEYCHAIN")
    fi
  elif [[ -f "$keychain" && -s "$password" && -s "$signing_dir/certificate.sha1" ]]; then
    sign_kind=own
    sign_identity="$(tr -d '[:space:]' <"$signing_dir/certificate.sha1")"
    sign_options+=(--keychain "$keychain")
    # The keychain locks when the Mac restarts. Its password goes in on standard input,
    # so it is never an argument that other programs could read.
    printf 'unlock-keychain -p "%s" "%s"\n' "$(cat "$password")" "$keychain" |
      security -i >/dev/null 2>&1 ||
      {
        echo "signing: cannot unlock $keychain. Run scripts/setup-signing again." >&2
        return 1
      }
  else
    sign_kind=adhoc
    sign_identity="-"
  fi
}

# Signs one piece of code with the hardened runtime, replacing any signature it had.
sign() {
  codesign --force --options runtime "${sign_options[@]}" --sign "$sign_identity" "$@"
}

# One line for the build log saying how the app is signed.
describe_signing() {
  case "$sign_kind" in
    own) echo "your Spaces certificate ($sign_identity): permissions carry over from build to build" ;;
    developer-id) echo "$sign_identity" ;;
    given) echo "$sign_identity (no time stamp, so no network is needed)" ;;
    adhoc) echo "no certificate (ad hoc)" ;;
  esac
}
