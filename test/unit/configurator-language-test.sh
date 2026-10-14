#!/bin/bash
#
# The configurator's language step and what it hands on: the language prompt
# comes before the keyboard on the first screen, a different language forgets
# a keyboard picked for the old one, the summary names the language, both
# archinstall configurations carry its locale and code, and the install
# dashboard speaks it without leaking it to the installer it runs.
#
# The configurator is sourced for its functions (it only runs main when
# executed) against a stand-in setup form that scripts each prompt's answer,
# and a stand-in omarchy-i18n that prints "[language]key args", so every
# assertion also shows which language a line was asked for in.
#
# No errexit or nounset: the configurator runs without them, and its functions
# are written for that. Every check fails explicitly instead.

set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

omarchy="$work/omarchy"
mkdir -p "$omarchy/bin" "$omarchy/default/i18n"
printf 'OMARCHY\n' >"$omarchy/logo.txt"
cat >"$omarchy/default/i18n/locales.json" <<'JSON'
{
  "en": {"name": "English", "englishName": "English", "locale": "en_US.UTF-8", "keyboard": "English (US)"},
  "da": {"name": "Dansk", "englishName": "Danish", "locale": "da_DK.UTF-8", "keyboard": "Danish"},
  "de": {"name": "Deutsch", "englishName": "German", "locale": "de_DE.UTF-8", "keyboard": "German"},
  "ja": {"name": "日本語", "englishName": "Japanese", "locale": "ja_JP.UTF-8", "keyboard": "Japanese", "console": false}
}
JSON
cat >"$omarchy/bin/omarchy-i18n" <<'I18N'
#!/bin/bash
language=en
if [[ -f ${OMARCHY_LANGUAGE_FILE:-} ]]; then
  language=$(head -n 1 "$OMARCHY_LANGUAGE_FILE")
fi
if [[ $1 == "--number" ]]; then
  printf '%s' "$2"
  exit 0
fi
printf '[%s]%s' "$language" "$*"
I18N
chmod +x "$omarchy/bin/omarchy-i18n"

# The stand-in form: each prompt pops its next scripted answer, "code:status"
# for the language and "label:status" for the keyboard, and records what the
# keyboard prompt was asked to preselect.
cat >"$work/setup-form.sh" <<'FORM'
OMARCHY_FORM_BACK=1
OMARCHY_FORM_SIGNAL=130
omarchy_console_font() { :; }
omarchy_language_label() { printf 'label(%s)' "$1"; }
language_answers=()
keyboard_answers=()
keyboard_preselected=()
omarchy_prompt_language() {
  local answer=${language_answers[0]}
  language_answers=("${language_answers[@]:1}")
  local status=${answer##*:}
  if ((status == 0)); then
    language=${answer%%:*}
    language_locale=$(jq -r --arg code "$language" '.[$code].locale' "$OMARCHY_PATH/default/i18n/locales.json")
    printf '%s\n' "$language" >"$TEST_WORK/language"
    export OMARCHY_LANGUAGE_FILE="$TEST_WORK/language"
  fi
  return "$status"
}
omarchy_prompt_keyboard() {
  local answer=${keyboard_answers[0]}
  keyboard_answers=("${keyboard_answers[@]:1}")
  keyboard_preselected+=("${keyboard_label:-<language default>}")
  local status=${answer##*:}
  if ((status == 0)); then
    keyboard_label=${answer%%:*}
    keyboard=us
  fi
  return "$status"
}
FORM

export OMARCHY_PATH="$omarchy" SETUP_FORM="$work/setup-form.sh" TEST_WORK="$work"
# shellcheck source=../../configs/airootfs/root/configurator
source "$CONFIGURATOR"

[[ $OMARCHY_LANGUAGE_FILE == /dev/null ]] ||
  fail "the configurator starts in English" "OMARCHY_LANGUAGE_FILE=$OMARCHY_LANGUAGE_FILE"
pass "the configurator starts in English, whatever the developer's desktop speaks"

# gum draws on the terminal; here it only has to answer.
gum_confirm_status=0
gum() {
  case $1 in
    confirm) return "$gum_confirm_status" ;;
    table) cat ;;
    choose) printf '%s\n' "${gum_choice:-}" ;;
    style) printf '%s\n' "${@: -1}" ;;
  esac
}

reset_form() {
  language="" language_locale="" keyboard_label="" keyboard=""
  defer_provisioning=false
  export OMARCHY_LANGUAGE_FILE=/dev/null
  keyboard_preselected=()
}

# Esc on the keyboard returns to the language; picking a different one there
# forgets the layout chosen for the first.
reset_form
language_answers=(da:0)
keyboard_answers=(Danish:0)
keyboard_form >/dev/null
[[ $language == "da" && $keyboard_label == "Danish" ]] ||
  fail "language then keyboard sets both" "language=$language keyboard_label=$keyboard_label"
language_answers=(de:0)
keyboard_answers=(German:0)
keyboard_preselected=()
keyboard_form >/dev/null
[[ ${keyboard_preselected[0]} == "<language default>" ]] ||
  fail "a different language forgets the old keyboard" "preselected: ${keyboard_preselected[*]}"
pass "a different language forgets the keyboard picked for the old one"

language_answers=(de:0)
keyboard_answers=(German:0)
keyboard_preselected=()
keyboard_form >/dev/null
[[ ${keyboard_preselected[0]} == "German" ]] ||
  fail "the same language keeps its keyboard" "preselected: ${keyboard_preselected[*]}"
pass "the same language keeps the keyboard already picked"

reset_form
language_answers=(da:0 da:0)
keyboard_answers=(x:1 Danish:0)
keyboard_form >/dev/null
(( ${#language_answers[@]} == 0 && ${#keyboard_answers[@]} == 0 )) ||
  fail "Esc on the keyboard returns to the language" "left: ${language_answers[*]} / ${keyboard_answers[*]}"
pass "Esc on the keyboard goes back to the language"

reset_form
language_answers=(x:1 da:0)
keyboard_answers=(Danish:0)
keyboard_form >/dev/null
[[ $language == "da" ]] || fail "Esc on the language re-asks it" "language=$language"
pass "Esc on the language asks it again"

for prompt in language keyboard; do
  reset_form
  if [[ $prompt == "language" ]]; then
    language_answers=(x:130)
    keyboard_answers=()
  else
    language_answers=(da:0)
    keyboard_answers=(x:130)
  fi
  keyboard_form >/dev/null
  $defer_provisioning || fail "Ctrl+C on the $prompt prompt offers deferred provisioning"
done
pass "Ctrl+C on either prompt still prepares the machine for another owner"

# Every later screen speaks the chosen language.
reset_form
language_answers=(da:0)
keyboard_answers=(Danish:0)
screen=$(keyboard_form; step "$(i18n installer.setupUser)")
grep -qF "[da]installer.setupUser" <<<"$screen" ||
  fail "screens after the language speak it" "$screen"
pass "the screens after the language step speak it"

# The summary names the language with the setup form's own label.
username=omarchy password=secret full_name="" email_address="" hostname=box timezone=UTC
reset_form
language=da keyboard_label=Danish
printf 'da\n' >"$work/language"
export OMARCHY_LANGUAGE_FILE="$work/language"
summary=$(summary_table)
grep -qP '^\[da\]installer.summaryLanguage\tlabel\(da\)$' <<<"$summary" ||
  fail "the summary names the language as the picker does" "$summary"
grep -qP '^\[da\]installer.summaryKeyboard\tDanish$' <<<"$summary" ||
  fail "the summary names the keyboard" "$summary"
grep -qP '^\[da\]installer.summaryFullName\t\[da\]installer.skipped$' <<<"$summary" ||
  fail "a skipped answer reads as skipped" "$summary"
pass "the summary shows the language as the picker labels it"

# The install mode is chosen by its translated label and stored as a value.
full_disk_only=true disk=/dev/vda
for choice in "[da]installer.fullDiskInstall:full_disk" "[da]installer.chooseDifferentDisk:other_disk"; do
  gum_choice=${choice%:*}
  install_mode_form >/dev/null
  [[ $install_mode == "${choice##*:}" ]] ||
    fail "install modes map back from their labels" "$gum_choice -> $install_mode"
done
pass "a translated install mode maps back to its value"

# Both archinstall configurations carry the locale and the language code.
cd "$work" || exit 1
lsblk() { echo 68719476736; }
detect_kernel() { echo linux-omarchy; }
language=da language_locale=da_DK.UTF-8
keyboard=dk keyboard_input_method=none keyboard_xkb_layout=""
defer_provisioning=false

for encrypt_installation in false true; do
  write_full_disk_configuration
  jq -e '.locale_config.sys_lang == "da_DK.UTF-8" and .omarchy_install.language == "da"' \
    user_configuration.json >/dev/null ||
    fail "the full-disk configuration carries the language (encrypted=$encrypt_installation)" "$(cat user_configuration.json)"
done

encrypt_installation=true needs_mklabel=false kernel_choice=linux-omarchy
efi_dev=x root_partition_device=x root_mapper=x esp_mount_in_target=/boot
run_partition_execute dry >/dev/null
jq -e '.locale_config.sys_lang == "da_DK.UTF-8" and .omarchy_install.language == "da"' \
  user_configuration.json >/dev/null ||
  fail "the free-space configuration carries the language" "$(cat user_configuration.json)"
pass "both archinstall configurations carry the language's locale and code"

language="" language_locale=""
write_full_disk_configuration
jq -e '.locale_config.sys_lang == "en_US.UTF-8" and .omarchy_install.language == "en"' \
  user_configuration.json >/dev/null ||
  fail "no language means English" "$(cat user_configuration.json)"
pass "with no language picked, the install is English"

# The dashboard runs after the configurator exits, so it reads what was left.
export OMARCHY_LANGUAGE_FILE="$work/language"
write_installer_language
[[ $(<installer_language) == "da" ]] || fail "the configurator leaves its language" "$(<installer_language)"
export OMARCHY_LANGUAGE_FILE=/dev/null
write_installer_language
[[ $(<installer_language) == "en" ]] || fail "an English run leaves English" "$(<installer_language)"
pass "the configurator leaves the language its screens spoke for the dashboard"

# The dashboard speaks that language, and the installer it runs never sees it.
printf 'da\n' >"$work/installer_language"
screen="$work/screen"
child_env="$work/child-env"
if command -v script >/dev/null 2>&1; then
  unset OMARCHY_LANGUAGE_FILE
  script -qefc "stty rows 40 cols 120; OMARCHY_PATH='$omarchy' OMARCHY_DASHBOARD_LANGUAGE_FILE='$work/installer_language' OMARCHY_UI_INTERACTIVE=no OMARCHY_UI_FAILURE_ACTION=exit '$DASHBOARD' '$work/install.log' '$work/state.json' -- bash -c 'env >\"$child_env\"; exit 1'" \
    "$screen" >/dev/null 2>&1 || true
  grep -qF "[da]installer.installationStopped" "$screen" ||
    fail "the dashboard speaks the installer's language" "$(tail -n 20 "$screen")"
  ! grep -q "^OMARCHY_LANGUAGE_FILE=" "$child_env" ||
    fail "the installer child doesn't inherit the dashboard's language" "$(grep LANGUAGE "$child_env")"
  pass "the dashboard speaks the installer's language without handing it to the installer"
else
  echo "SKIP: script (util-linux) is not installed; dashboard language not checked"
fi
