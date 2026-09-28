#!/usr/bin/env bash
set -euo pipefail

# Exercise recipient rotation entirely in a mode-0700 temporary directory.
# The two scenarios replace the primary and recovery recipients respectively,
# and both rotate every managed file type used by this repository. Plaintext
# and identity files are disposable fixtures only; no fixture value is ever
# printed or passed as a command argument.

SOPS_BIN=${SOPS_BIN:-sops}
AGE_KEYGEN_BIN=${AGE_KEYGEN_BIN:-age-keygen}

die() {
    echo "SOPS recipient rotation test failed: $*" >&2
    exit 1
}

resolve_tool() {
    local requested=$1
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || die "tool is not executable"
        printf '%s\n' "$requested"
    else
        command -v "$requested" || die "required tool is unavailable"
    fi
}

SOPS_BIN=$(resolve_tool "$SOPS_BIN")
AGE_KEYGEN_BIN=$(resolve_tool "$AGE_KEYGEN_BIN")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sops-recipient-rotation.XXXXXX")

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-sops-recipient-rotation."* ]]; then
        find "$WORK" -depth -delete
    fi
}
trap cleanup EXIT

mkdir -m 700 "$WORK/home" "$WORK/config"
: >"$WORK/sops.yaml"

generate_identity() {
    local identity=$1
    local recipient_file=$2

    "$AGE_KEYGEN_BIN" -o "$identity" >"$WORK/keygen.out" 2>"$WORK/keygen.err" ||
        die "could not create disposable age identity"
    chmod 0600 "$identity"
    [[ "$(stat -c '%a' -- "$identity")" == 600 ]] ||
        die "disposable age identity is not mode 0600"
    "$AGE_KEYGEN_BIN" -y "$identity" >"$recipient_file" 2>>"$WORK/keygen.err" ||
        die "could not derive disposable age recipient"
    tr -d '\r\n' <"$recipient_file" >"$recipient_file.normalized"
}

sops_without_identity() {
    env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE -u SOPS_AGE_KEY_CMD \
        -u SOPS_AGE_SSH_PRIVATE_KEY_FILE -u SOPS_AGE_SSH_PRIVATE_KEY_CMD \
        -u SOPS_AGE_RECIPIENTS \
        SOPS_CONFIG="$WORK/sops.yaml" HOME="$WORK/home" \
        XDG_CONFIG_HOME="$WORK/config" "$SOPS_BIN" "$@"
}

sops_with_identity() {
    local identity=$1
    shift
    # The private key travels only through a mode-0600 file named by this
    # environment variable; it is never present in argv or shell output.
    env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_CMD \
        -u SOPS_AGE_SSH_PRIVATE_KEY_FILE -u SOPS_AGE_SSH_PRIVATE_KEY_CMD \
        -u SOPS_AGE_RECIPIENTS \
        SOPS_CONFIG="$WORK/sops.yaml" SOPS_AGE_KEY_FILE="$identity" \
        HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" "$SOPS_BIN" "$@"
}

write_fixture() {
    local type=$1
    local output=$2
    local bootstrap_b2_field='BOOTSTRAP_''B2_APPLICATION_KEY'
    local bootstrap_restic_field='BOOTSTRAP_''RESTIC_PASSWORD'
    local b2_account_id_field='B2_''ACCOUNT_ID'
    local b2_account_key_field='B2_''ACCOUNT_KEY'
    local restic_repository_field='RESTIC_''REPOSITORY'
    local restic_password_field='RESTIC_''PASSWORD'

    case "$type" in
        dotenv)
            printf '%s=%s\n%s=%s\n' \
                "$bootstrap_b2_field" 'rotation-fixture-b2' \
                "$bootstrap_restic_field" 'rotation-fixture-restic' >"$output"
            ;;
        yaml)
            printf '%s\n' \
                'bootstrap_backup_enabled: true' \
                'bootstrap_restic_env:' >"$output"
            printf '  %s: %s\n  %s: %s\n  %s: %s\n  %s: %s\n' \
                "$b2_account_id_field" 'rotation-fixture-account' \
                "$b2_account_key_field" 'rotation-fixture-key' \
                "$restic_repository_field" 'rotation-fixture-repository' \
                "$restic_password_field" 'rotation-fixture-password' >>"$output"
            ;;
        *)
            die "unsupported fixture type: $type"
            ;;
    esac
}

assert_recipient_set() {
    local file=$1
    local retained_recipient=$2
    local new_recipient=$3
    local retired_recipient=$4

    grep -Fq -- "$retained_recipient" "$file" ||
        die "retained recipient is missing from rotated ciphertext"
    grep -Fq -- "$new_recipient" "$file" ||
        die "replacement recipient is missing from rotated ciphertext"
    if grep -Fq -- "$retired_recipient" "$file"; then
        die "retired recipient remains in rotated ciphertext"
    fi
}

decrypt_and_compare() {
    local identity=$1
    local type=$2
    local ciphertext=$3
    local expected=$4
    local label=$5
    local decrypted="$WORK/$label.decrypted"

    sops_with_identity "$identity" decrypt \
        --input-type "$type" --output-type "$type" "$ciphertext" \
        >"$decrypted" 2>"$WORK/$label.decrypt.err" ||
        die "$label could not decrypt rotated ciphertext"
    case "$type" in
        dotenv)
            cmp -s "$expected" "$decrypted" ||
                die "$label plaintext changed during recipient rotation"
            ;;
        yaml)
            # SOPS may quote decrypted YAML scalar values even when the
            # source used plain scalars. Check the parsed contract without
            # printing the disposable fixture values.
            [[ "$(wc -l <"$decrypted")" == 6 ]] ||
                die "$label YAML field count changed during rotation"
            grep -Eq '^bootstrap_backup_enabled: true$' "$decrypted" ||
                die "$label YAML boolean changed during rotation"
            grep -Eq '^[[:space:]]+B2_ACCOUNT_ID: "?rotation-fixture-account"?$' "$decrypted" ||
                die "$label YAML account changed during rotation"
            grep -Eq '^[[:space:]]+B2_ACCOUNT_KEY: "?rotation-fixture-key"?$' "$decrypted" ||
                die "$label YAML account key changed during rotation"
            grep -Eq '^[[:space:]]+RESTIC_REPOSITORY: "?rotation-fixture-repository"?$' "$decrypted" ||
                die "$label YAML repository changed during rotation"
            grep -Eq '^[[:space:]]+RESTIC_PASSWORD: "?rotation-fixture-password"?$' "$decrypted" ||
                die "$label YAML password changed during rotation"
            ;;
        *)
            die "unsupported comparison type: $type"
            ;;
    esac
}

assert_old_identity_fails() {
    local identity=$1
    local type=$2
    local ciphertext=$3
    local label=$4
    local output="$WORK/$label.retired.out"

    if sops_with_identity "$identity" decrypt \
        --input-type "$type" --output-type "$type" "$ciphertext" \
        >"$output" 2>"$WORK/$label.retired.err"; then
        die "$label retired identity still decrypts rotated ciphertext"
    fi
    [[ ! -s "$output" ]] || die "$label failed decryption emitted plaintext"
}

assert_no_private_identity_material() {
    local private_key_marker='AGE-SECRET-''KEY-'
    local plaintext_marker='rotation-fixture-'
    local artifact name

    while IFS= read -r -d '' artifact; do
        name=${artifact##*/}
        case "$name" in
            *.identity|*.plain|*.plain.*|*.decrypted)
                continue
                ;;
        esac
        if grep -Fq -- "$private_key_marker" "$artifact"; then
            die "private identity material appeared in emitted artifact"
        fi
        if grep -Fq -- "$plaintext_marker" "$artifact"; then
            die "plaintext fixture material appeared in emitted artifact"
        fi
    done < <(find "$WORK" -type f -print0)
}

run_scenario() {
    local scenario=$1
    local old_role=$2
    local retained_role=$3
    local new_role=$4
    local scenario_dir="$WORK/$scenario"
    local old_identity="$scenario_dir/$old_role.identity"
    local retained_identity="$scenario_dir/$retained_role.identity"
    local new_identity="$scenario_dir/$new_role.identity"
    local old_recipient_file="$scenario_dir/$old_role.recipient"
    local retained_recipient_file="$scenario_dir/$retained_role.recipient"
    local new_recipient_file="$scenario_dir/$new_role.recipient"
    local old_recipient retained_recipient new_recipient
    local plain ciphertext before type suffix label

    mkdir -m 700 "$scenario_dir"
    generate_identity "$old_identity" "$old_recipient_file"
    generate_identity "$retained_identity" "$retained_recipient_file"
    generate_identity "$new_identity" "$new_recipient_file"
    old_recipient=$(<"$old_recipient_file.normalized")
    retained_recipient=$(<"$retained_recipient_file.normalized")
    new_recipient=$(<"$new_recipient_file.normalized")

    # These are the two encrypted file classes managed by the repository.
    for suffix in sops.env sops.yml; do
        case "$suffix" in
            sops.env)
                type=dotenv
                ;;
            sops.yml)
                type=yaml
                ;;
        esac
        plain="$scenario_dir/fixture.$suffix.plain"
        ciphertext="$scenario_dir/fixture.$suffix"
        before="$scenario_dir/fixture.$suffix.before"
        label="$scenario-$suffix"

        write_fixture "$type" "$plain"
        sops_without_identity encrypt --age "$old_recipient,$retained_recipient" \
            --input-type "$type" --output-type "$type" "$plain" \
            >"$ciphertext" 2>"$WORK/$label.encrypt.err" ||
            die "$label initial encryption failed"
        cp "$ciphertext" "$before"
        if cmp -s "$plain" "$ciphertext"; then
            die "$label was not encrypted"
        fi
        grep -Fq -- "$old_recipient" "$ciphertext" ||
            die "$label initial ciphertext omitted the old recipient"
        grep -Fq -- "$retained_recipient" "$ciphertext" ||
            die "$label initial ciphertext omitted the retained recipient"

        sops_with_identity "$retained_identity" filestatus "$ciphertext" \
            >"$WORK/$label.before-status.json" 2>"$WORK/$label.before-status.err" ||
            die "$label initial ciphertext status check failed"
        grep -Eq '"encrypted"[[:space:]]*:[[:space:]]*true' \
            "$WORK/$label.before-status.json" || die "$label was not reported encrypted"

        # rotate creates a fresh data key and changes the recipient envelope;
        # the retained identity is the recovery proof needed before retirement.
        sops_with_identity "$retained_identity" rotate --in-place \
            --input-type "$type" --output-type "$type" \
            --add-age "$new_recipient" --rm-age "$old_recipient" "$ciphertext" \
            >"$WORK/$label.rotate.out" 2>"$WORK/$label.rotate.err" ||
            die "$label recipient rotation failed"
        if cmp -s "$before" "$ciphertext"; then
            die "$label was not re-encrypted during rotation"
        fi

        assert_recipient_set "$ciphertext" "$retained_recipient" \
            "$new_recipient" "$old_recipient"
        sops_with_identity "$retained_identity" filestatus "$ciphertext" \
            >"$WORK/$label.after-status.json" 2>"$WORK/$label.after-status.err" ||
            die "$label rotated ciphertext status check failed"
        grep -Eq '"encrypted"[[:space:]]*:[[:space:]]*true' \
            "$WORK/$label.after-status.json" || die "$label rotated file was not reported encrypted"

        decrypt_and_compare "$retained_identity" "$type" "$ciphertext" "$plain" \
            "$label-retained"
        decrypt_and_compare "$new_identity" "$type" "$ciphertext" "$plain" \
            "$label-replacement"
        assert_old_identity_fails "$old_identity" "$type" "$ciphertext" "$label"
    done
}

# Replacing the primary retains the offline recovery identity. Replacing the
# recovery recipient retains the primary identity. Both paths must work for
# every managed ciphertext before the old identity is retired.
run_scenario primary-replacement primary-old recovery-retained primary-new
run_scenario recovery-replacement recovery-old primary-retained recovery-new
assert_no_private_identity_material

printf '%s\n' 'SOPS primary and recovery recipient rotation tests passed'
