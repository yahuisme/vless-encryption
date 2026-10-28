"""Extracted-function regression; no installer entrypoint or host services."""
import pathlib,re,subprocess,tempfile,unittest,os
SRC=(pathlib.Path(__file__).resolve().parents[1]/'install.sh').read_text()
def extract(n):
 m=re.search(r'^'+n+r'\(\) \{[^\n]*\n.*?^\}',SRC,re.M|re.S)
 one=re.search(r'^'+n+r'\(\) \{.*\}\s*$',SRC,re.M)
 if one: return one[0]
 assert m,n
 return m[0]
class Tests(unittest.TestCase):
 def run_case(self,names,body):
  with tempfile.TemporaryDirectory(prefix='encryption-test-') as d:
   setup='''set -euo pipefail
RUN="$PWD"; XRAY_BIN="$RUN/core"; XRAY_CONFIG="$RUN/config.json"; ENCRYPTION_INFO="$RUN/encryption.info"; REALITY_INFO="$RUN/reality.info"; SUBSCRIPTION_INFO="$RUN/link"; ROLLBACK_DIR=""; INSTALL_ROLLBACK_DIR=""
AUTH_MODE=mlkem768; TRAFFIC_MODE=native
C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_MAGENTA=''
error() { printf 'ERROR %s\\n' "$*" >&2; }; warning() { :; }; info() { :; }; success() { :; }; print_step() { :; }; cecho() { :; }; print_divider() { :; }
systemctl() { return 99; }; kill() { exit 99; }; pkill() { exit 99; }; pgrep() { return 99; }; apt-get() { exit 99; }; curl() { exit 99; }; sleep() { :; }
'''
   if 'restore_install_snapshot' in names:
    names=list(dict.fromkeys(names+['xray_pids','stop_xray_processes']))
    setup+='\npgrep() { return 1; }\n'
   text='\n'.join(extract(n) for n in names)
   for a,b in [('/etc/systemd/system',d+'/system'),('/usr/local/share/xray',d+'/geo'),('/usr/local/etc/xray',d+'/etc'),('/var/log/xray',d+'/logs'),('/tmp/xray-',d+'/snapshot-'),('/proc/',d+'/proc/')]:text=text.replace(a,b)
   f=pathlib.Path(d)/'fixture.sh';f.write_text(setup+text+'\n'+body)
   o=subprocess.run(['bash',str(f)],cwd=d,text=True,capture_output=True,timeout=15)
   self.assertEqual(o.returncode,0,o.stdout+o.stderr);return o
 def test_mainpid_without_modern_value_flag(self):
  self.run_case(['xray_main_pid'],r'''
systemctl() { [[ "$*" != *--value* ]] || return 1; printf 'MainPID=12\n'; }
readlink() { printf '%s' "$XRAY_BIN"; }
[[ $(xray_main_pid) = 12 ]]
for reply in MainPID=0 MainPID=bad $'MainPID=12\nMainPID=13'; do
 systemctl() { printf '%s\n' "$reply"; }
 if xray_main_pid; then exit 81; fi
done
''')
 def test_service_account_uses_effective_properties(self):
  self.run_case(['service_account'],r'''
systemctl() {
 [[ "$*" != *--value* ]] || return 1
 case "$*" in *User*) printf 'User=root\n';; *Group*) printf 'Group=root\n';; *) return 1;; esac
}
[[ $(service_account) = root:root ]]
systemctl() { return 1; }
if service_account; then exit 81; fi
''')
 def test_modify_preserves_stopped_service(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
systemctl() { [[ "$1" != is-active ]]; }
write_config() { touch written; }
restart_xray() { touch wrongly-started; }
clear_rollback() { :; }; show_subscription() { :; }
modify_config || exit 81
[[ -f written && ! -e wrongly-started ]]
''')
 def test_failed_modify_stop_preserves_snapshot(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
systemctl() { [[ "$1" != stop ]]; }
write_config() { :; }
restart_xray() { return 1; }
rollback_config() { touch wrongly-restored; }
if modify_config; then exit 81; fi
[[ ! -e wrongly-restored ]]
''')
 def test_public_ip_rejects_bad_cache_and_response(self):
  self.run_case(['public_ip','valid_ipv4','valid_ipv6'],r'''
mkdir -p "$RUN/etc"
printf 'bad@host/path\n' > "$RUN/etc/.public-ip"
curl() { if [[ "$*" = -4* ]]; then printf '203.0.113.7'; else return 1; fi; }
[[ $(public_ip) = 203.0.113.7 ]]
printf '001.2.3.4\n' > "$RUN/etc/.public-ip"
curl() { if [[ "$*" = -4* ]]; then printf '999999999999999999999.1.1.1'; else printf '2001:db8::7'; fi; }
[[ $(public_ip) = '[2001:db8::7]' ]]
''')
 def test_keygen_partial_failure_is_rejected(self):
  self.run_case(['generate_reality_keys','validate_reality_key'],r'''
printf '#!/bin/sh\nprintf "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\nPassword: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n"\nexit 7\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
if generate_reality_keys; then exit 81; fi
''')
 def test_encryption_keygen_partial_failure_is_rejected(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  self.run_case(['generate_encryption_pair','extract_vlessenc_value','validate_encryption_token','valid_appearance'],r'''
printf '#!/bin/sh\n"%s" vlessenc\nexit 7\n' "$XRAY_TEST_BINARY" > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
if generate_encryption_pair; then exit 81; fi
''')
 def test_invalid_cli_never_installs_dependencies(self):
  for args in ('install --unknown', 'install --port', 'install --port 0', 'install --auth invalid', 'install --short-id aa'):
   with self.subTest(args=args):
    self.run_case(['main','valid_port','valid_auth','valid_appearance','valid_uuid','show_help'],r'''
    require_root_and_dependencies() { touch dependencies; }
    show_help() { :; }
    cat() { printf '00000000-0000-4000-8000-000000000000'; }
    ''' + f'if (main {args}); then exit 81; fi\n[[ ! -e dependencies ]]\n')
 def test_real_modify_switches_both_directions(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  names=['modify_config','valid_port','valid_uuid','valid_sni','valid_short_id','valid_appearance','current_port','extract_vlessenc_value','validate_encryption_token','generate_encryption_pair','validate_reality_key','generate_reality_keys','write_config','clear_rollback','rollback_config']
  self.run_case(names,r'''
XRAY_BIN="$XRAY_TEST_BINARY"
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
systemctl() { return 0; }
read() { if [[ "$*" = *' -p '* ]]; then case "${!#}" in choice) choice=2;; input) input='';; esac; else builtin read "$@"; fi; }
restart_xray() { "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; }
show_subscription() { :; }
pair=$(generate_encryption_pair); IFS='|' read -r dec enc <<< "$pair"
write_config 18443 00000000-0000-4000-8000-000000000000 "$dec" "$enc" encryption
clear_rollback
jq '.dns={servers:["1.1.1.1"]}' "$XRAY_CONFIG" > extra; mv extra "$XRAY_CONFIG"
for expected in reality none; do
 modify_config || exit 81
 jq -e --arg expected "$expected" '(.inbounds[0].streamSettings.security // "none")==$expected and .dns.servers==["1.1.1.1"]' "$XRAY_CONFIG" >/dev/null
 [[ -z "$ROLLBACK_DIR" ]]
done
''')
 def test_public_ip_cache_and_write_failures(self):
  self.run_case(['public_ip','valid_ipv4','valid_ipv6'],r'''
curl() { printf '203.0.113.9'; }
[[ $(public_ip) = 203.0.113.9 ]]
mkdir -p "$RUN/etc"
printf '[2001:db8::9]\n' > "$RUN/etc/.public-ip"
curl() { return 99; }
[[ $(public_ip) = '[2001:db8::9]' ]]
touch -d '2 days ago' "$RUN/etc/.public-ip"
curl() { [[ "$*" = -4* ]] && printf '203.0.113.9' || return 1; }
[[ $(public_ip) = 203.0.113.9 ]]
rm "$RUN/etc/.public-ip"; mkdir "$RUN/etc/.public-ip"
[[ $(public_ip) = 203.0.113.9 ]]
curl() { return 1; }
if public_ip; then exit 81; fi
''')
 def test_official_geodata_write_failure_is_fatal(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['run_official_installer','normalize_official_writes'],r'''
XRAY_INSTALL_URL=fixture XRAY_INSTALL_SHA256=fixture
curl() { cat "$PINNED_INSTALLER"; }
sha256sum() { return 0; }
bash() {
 local file="$1"
 awk '/^install_geodata\(\)/ {inside=1} inside {print} inside && /^}/ {exit}' "$file" > "$RUN/geodata.sh"
 cat >> "$RUN/geodata.sh" <<'SHELL'
TMP_DIRECTORY="$RUN/download"; DAT_PATH="$RUN/data"; XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1; PROXY=''
mkdir -p "$DAT_PATH"
curl() { local output; while [[ $# -gt 0 ]]; do if [[ "$1" = -o ]]; then output="$2"; shift 2; else shift; fi; done; printf fixture > "$output"; }
sha256sum() { return 0; }
install() { return 1; }
install_geodata
SHELL
 command bash "$RUN/geodata.sh"
}
if run_official_installer install-geodata; then exit 81; fi
''')
 def test_official_core_write_guards(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['normalize_official_writes'],r'''
cp "$PINNED_INSTALLER" official
normalize_official_writes official || exit 81
awk '/^install_file\(\)/ {inside=1} inside {print} inside && /^}/ {exit}' official > "$RUN/core-write.sh"
cat >> "$RUN/core-write.sh" <<'SHELL'
TMP_DIRECTORY="$RUN"; DAT_PATH="$RUN"
install() { [[ "$FAULT" = none ]]; }
install_file xray
printf completed
SHELL
if FAULT=write-failure command bash "$RUN/core-write.sh"; then exit 81; fi
[[ $(FAULT=none command bash "$RUN/core-write.sh") = completed ]]
if normalize_official_writes official; then exit 81; fi
''')
 def test_current_schema_and_legacy_migration(self):
  self.run_case(['write_config'],r'''
validate_encryption_token() { :; }; validate_reality_key() { :; }; valid_sni() { :; }; valid_short_id() { :; }
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '%s' '{"inbounds":[{"settings":{"clients":[{"id":"old"},{"id":"extra"}]},"streamSettings":{"network":"tcp","tcpSettings":{"header":{"type":"none"}},"security":"reality","realitySettings":{"dest":"old.example:443","serverNames":["old.example"],"shortIds":["aa","bb"]}}}],"dns":{"servers":["1.1.1.1"]}}' > "$XRAY_CONFIG"
jq '.outbounds=[{protocol:"freedom",settings:{domainStrategy:"UseIPv4v6",targetStrategy:"",redirect:"127.0.0.1:80"}}]' "$XRAY_CONFIG" > extra; mv extra "$XRAY_CONFIG"
write_config 443 uuid dec enc reality private public new.example 20220701 true
jq -e '.outbounds[0] | .streamSettings.sockopt.domainStrategy=="UseIPv4v6" and .settings.redirect=="127.0.0.1:80" and (.settings|has("domainStrategy")|not) and (.settings|has("targetStrategy")|not)' "$XRAY_CONFIG" >/dev/null
jq -e '.inbounds[0] | (.settings.users[0].id=="uuid" and .settings.users[1].id=="extra" and (.settings|has("clients")|not) and .streamSettings.method=="raw" and (.streamSettings|has("network")|not) and .streamSettings.rawSettings.header.type=="none" and .streamSettings.realitySettings.target=="new.example:443" and (.streamSettings.realitySettings|has("dest")|not))' "$XRAY_CONFIG" >/dev/null
jq -e '.dns.servers==["1.1.1.1"]' "$XRAY_CONFIG" >/dev/null
''')
 def test_subscription_reads_current_and_legacy_users(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  self.run_case(['show_subscription','valid_port','valid_uuid','validate_encryption_token','valid_appearance','uri_encode','generate_encryption_pair','extract_vlessenc_value'],r'''
XRAY_BIN="$XRAY_TEST_BINARY"
pair=$(generate_encryption_pair); enc=${pair#*|}
printf '%s\n' "$enc" > "$ENCRYPTION_INFO"
public_ip() { printf '[2001:db8::7]'; }
for field in users clients; do
 jq -n --arg field "$field" '{inbounds:[{port:443,settings:{($field):[{id:"00000000-0000-4000-8000-000000000000"}],decryption:"old"}}]}' > "$XRAY_CONFIG"
 show_subscription || exit 81
 [[ $(cat "$SUBSCRIPTION_INFO") = 'vless://00000000-0000-4000-8000-000000000000@[2001:db8::7]:443?'* ]]
 [[ $(cat "$SUBSCRIPTION_INFO") = *'type=tcp'* ]]
done
''')
 def test_existing_mldsa_seed_is_exported(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  names=['show_subscription','valid_port','valid_uuid','valid_sni','valid_short_id','validate_reality_key','validate_encryption_token','valid_appearance','uri_encode','generate_encryption_pair','extract_vlessenc_value']
  self.run_case(names,r'''
XRAY_BIN="$XRAY_TEST_BINARY"
pair=$(generate_encryption_pair); enc=${pair#*|}; printf '%s\n' "$enc" > "$ENCRYPTION_INFO"
keys=$("$XRAY_BIN" mldsa65); seed=$(awk '/^Seed:/ {print $2}' <<< "$keys"); verify=$(awk '/^Verify:/ {print $2}' <<< "$keys")
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|www.example.com|aa\n' > "$REALITY_INFO"
jq -n --arg seed "$seed" '{inbounds:[{port:443,settings:{users:[{id:"00000000-0000-4000-8000-000000000000"}],decryption:"old"},streamSettings:{security:"reality",realitySettings:{mldsa65Seed:$seed}}}]}' > "$XRAY_CONFIG"
public_ip() { printf '203.0.113.7'; }
show_subscription || exit 81
[[ $(cat "$SUBSCRIPTION_INFO") = *"&pqv=$verify"* ]]
''')
 def test_official_wrapper_constrains_environment_paths(self):
  if not os.environ.get('PINNED_INSTALLER'):self.skipTest('set PINNED_INSTALLER to verified fixed upstream source')
  self.run_case(['run_official_installer','normalize_official_writes'],r'''
XRAY_INSTALL_URL=fixture XRAY_INSTALL_SHA256=fixture
curl() { cat "$PINNED_INSTALLER"; }
sha256sum() { return 0; }
export DAT_PATH="$RUN/unrelated" JSON_PATH="$RUN/other-config" JSONS_PATH="$RUN/split-config"
bash() {
 [[ "$DAT_PATH" = "$RUN/geo" && "$JSON_PATH" = "$RUN/etc" && -z "$JSONS_PATH" ]]
}
run_official_installer install-geodata || exit 81
[[ "$DAT_PATH" = "$RUN/unrelated" && "$JSON_PATH" = "$RUN/other-config" && "$JSONS_PATH" = "$RUN/split-config" ]]
''')
 def test_official_core_matrix(self):
  binary=os.environ.get('XRAY_TEST_BINARY')
  if not binary:self.skipTest('set XRAY_TEST_BINARY to a verified official core')
  self.run_case(['valid_appearance','valid_sni','valid_short_id','extract_vlessenc_value','validate_encryption_token','generate_encryption_pair','validate_reality_key','generate_reality_keys','write_config','clear_rollback','rollback_config'],r'''
XRAY_BIN="$XRAY_TEST_BINARY"
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
for AUTH_MODE in x25519 mlkem768; do
 for TRAFFIC_MODE in native xorpub random; do
  pair=$(generate_encryption_pair); IFS='|' read -r dec enc <<< "$pair"
  keys=$(generate_reality_keys); IFS='|' read -r private public <<< "$keys"
  preserve=false
  for mode in encryption reality encryption; do
   write_config 18443 00000000-0000-4000-8000-000000000000 "$dec" "$enc" "$mode" "$private" "$public" www.example.com 20220701 "$preserve"
   clear_rollback
   jq '.inbounds[0].tag="custom" | .dns={servers:["1.1.1.1"]}' "$XRAY_CONFIG" > "$RUN/extra.json"
   mv "$RUN/extra.json" "$XRAY_CONFIG"
   preserve=true
  done
  jq -e '.inbounds[0].tag=="custom" and .dns.servers==["1.1.1.1"]' "$XRAY_CONFIG" >/dev/null
 done
done
''')
 def test_review_rollback_boundaries(self):
  names=['restore_install_snapshot','clear_install_snapshot','begin_install_snapshot','xray_pids','stop_xray_processes']
  self.run_case(names,r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/system" "$RUN/geo"
printf OLD > "$INSTALL_ROLLBACK_DIR/xray"; printf OLDUNIT > "$INSTALL_ROLLBACK_DIR/xray.service"; printf NEW > "$XRAY_BIN"
pgrep() { [[ ! -e terminated ]] || return 1; printf 12; }; readlink() { printf '%s' "$XRAY_BIN"; }
kill() { touch terminated; }; systemctl() { return 0; }
restore_install_snapshot
[[ -e terminated && ! -e "$RUN/snapshot" && $(< "$XRAY_BIN") = OLD ]]
''')
  self.run_case(names,r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/system" "$RUN/geo"
printf NEW > "$XRAY_BIN"; printf UNIT > "$RUN/system/xray.service"
systemctl() { [[ $1 != disable ]]; }; pgrep() { return 1; }
if restore_install_snapshot; then exit 81; fi
[[ -e "$XRAY_BIN" && -e "$RUN/system/xray.service" && -d "$INSTALL_ROLLBACK_DIR" ]]
''')
  self.run_case(names,r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/geo"
systemctl() { case $1 in stop) return 5;; is-active) return 1;; *) return 0;; esac; }; pgrep() { return 1; }
restore_install_snapshot
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
begin_install_snapshot
''')
 def test_install_failure_and_retry(self):
  names=['install_selected','begin_install_snapshot','restore_install_snapshot','clear_install_snapshot','abort_install','clear_rollback']
  for existing in (False,True):
   self.run_case(names,r'''
mkdir -p "$RUN/system" "$RUN/geo"
systemctl() { case "$1" in is-active) [[ -f active ]];; stop) rm -f active;; *) return 0;; esac; }
restart_xray() { touch active; }
run_official_installer() {
 if [[ "$1" = install ]]; then
  printf NEW > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
  mkdir -p "$RUN/system/xray.service.d" "$RUN/system/xray@.service.d"
  printf UNIT > "$RUN/system/xray.service"
  rm -f active
  return 0
 fi
 return 1
}
'''+('''printf OLD > "$XRAY_BIN"; chmod +x "$XRAY_BIN"; printf ORIGINAL > "$XRAY_CONFIG"; chmod 640 "$XRAY_CONFIG"; printf UNIT > "$RUN/system/xray.service"; touch active
''' if existing else '')+r'''
if install_selected 443 uuid encryption; then exit 81; fi
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
'''+('''[[ "$(<"$XRAY_BIN")" = OLD && "$(<"$XRAY_CONFIG")" = ORIGINAL && -f active ]]
[[ $(stat -c %a "$XRAY_CONFIG") = 640 ]]
''' if existing else '''[[ ! -e "$XRAY_BIN" && ! -e "$RUN/system/xray.service.d" ]]
if install_selected 443 uuid encryption; then exit 81; fi
[[ -z "$INSTALL_ROLLBACK_DIR" ]]
'''))
 def test_update_preserves_stopped(self):
  self.run_case(['update_xray','begin_install_snapshot','clear_install_snapshot'],r'''
mkdir -p "$RUN/system" "$RUN/geo"; printf UNIT > "$RUN/system/xray.service"
printf OLD > "$XRAY_BIN"
systemctl() { [[ "$1" != is-active ]]; }
run_official_installer() { printf NEW > "$XRAY_BIN"; }
restart_xray() { exit 81; }
update_xray
[[ "$(<"$XRAY_BIN")" = NEW && -z "$INSTALL_ROLLBACK_DIR" ]]
''')
 def test_stop_failure_retains_recovery(self):
  self.run_case(['restore_install_snapshot'],r'''
INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir -p "$INSTALL_ROLLBACK_DIR"
printf ORIGINAL > "$INSTALL_ROLLBACK_DIR/config.json"; printf NEW > "$XRAY_CONFIG"
mkdir -p "$RUN/system"; printf UNIT > "$RUN/system/xray.service"
systemctl() { return 1; }
if restore_install_snapshot; then exit 81; fi
[[ "$(<"$XRAY_CONFIG")" = NEW && -f "$INSTALL_ROLLBACK_DIR/config.json" ]]
''')
 def test_failed_restore_does_not_restart_partial_config(self):
  self.run_case(['modify_config','valid_port','valid_uuid'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf enc > "$ENCRYPTION_INFO"
section_title() { :; }; menu_item() { :; }; prompt_default() { :; }
current_port() { printf 443; }
read() { case "${!#}" in choice) choice=1;; input) input='';; esac; }
write_config() { :; }
systemctl() { return 0; }
restart_xray() { if [[ -e restarted ]]; then touch BAD_SECOND_RESTART; fi; touch restarted; return 1; }
rollback_config() { return 1; }
modify_config || true
[[ ! -e BAD_SECOND_RESTART ]]
''')
 def test_process_identity_and_failure(self):
  self.run_case(['xray_pids','stop_xray_processes'],r'''
pgrep() { [[ ! -f stopped ]] || return 1; printf '12\n13\n'; }
readlink() { case "$1" in */12/exe) printf '%s (deleted)' "$XRAY_BIN";; *) printf /other;; esac; }
kill() { [[ "$*" = '-TERM 12' ]] || exit 81; touch stopped; }
stop_xray_processes
[[ -f stopped ]]
pgrep() { return 2; }
if stop_xray_processes; then exit 82; fi
''')
 def test_uninstall_query_failure_keeps_files(self):
  self.run_case(['uninstall_xray','has_xray_residue','xray_pids','stop_xray_processes'],r'''
printf ORIGINAL > "$XRAY_CONFIG"
read() { confirm=y; }; systemctl() { return 1; }; pgrep() { return 2; }
if uninstall_xray; then exit 81; fi
[[ "$(<"$XRAY_CONFIG")" = ORIGINAL ]]
''')
 def test_stable_and_changed_pid(self):
  self.run_case(['restart_xray','xray_main_pid'],r'''
systemctl() { if [[ "$1" = show ]]; then if [[ -e changed ]]; then printf 'MainPID=13'; else printf 'MainPID=12'; fi; fi; }
readlink() { printf '%s' "$XRAY_BIN"; }
sleep() { :; }
restart_xray
sleep() { touch changed; }
if restart_xray; then exit 81; fi
''')
 def test_port_fallback(self):
  self.run_case(['port_in_use','check_port'],r'''
ss() { return 2; }; netstat() { return 0; }
check_port 443
netstat() { printf 'tcp 0 0 :::443 :::* LISTEN\n'; }
if check_port 443; then exit 81; fi
ss() { return 0; }
check_port 443
''')
 def test_recovery_blocks_new_snapshot(self):
  self.run_case(['begin_install_snapshot'],r'''
INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir -p "$INSTALL_ROLLBACK_DIR"
printf ORIGINAL > "$INSTALL_ROLLBACK_DIR/config.json"
if begin_install_snapshot; then exit 81; fi
[[ "$INSTALL_ROLLBACK_DIR" = "$RUN/pending" ]]
''')
 def test_dependency_installs_process_tools(self):
  o=self.run_case(['require_root_and_dependencies'],r'''
id() { printf 0; }
command() { if [[ "$*" = '-v pgrep' && ! -e ready ]]; then return 1; fi; builtin command "$@"; }
apt-get() { printf '%s\n' "$*"; touch ready; }
require_root_and_dependencies
[[ -f ready ]]
''')
  self.assertIn('procps',o.stdout)
 def test_menu_keeps_recovery_reference(self):
  self.run_case(['main_menu'],r'''
print_header() { :; }; menu_item() { :; }
read() { if [[ "$*" = *choice ]]; then if [[ ! -e entered ]]; then choice=1; touch entered; else choice=0; fi; fi; }
interactive_install() { INSTALL_ROLLBACK_DIR="$RUN/pending"; mkdir -p "$INSTALL_ROLLBACK_DIR"; return 1; }
main_menu
[[ "$INSTALL_ROLLBACK_DIR" = "$RUN/pending" ]]
''')
 def test_awk_parser_has_no_warning(self):
  o=self.run_case(['extract_vlessenc_value'],'''value=$(extract_vlessenc_value $'Authentication: X\\n"encryption": "test"' 'Authentication: X' encryption)
[[ "$value" = test ]]''')
  self.assertEqual(o.stderr,'')
 def test_config_recovery_blocks_new_write(self):
  self.run_case(['write_config'],r'''
ROLLBACK_DIR="$RUN/pending"; mkdir -p "$ROLLBACK_DIR"
validate_encryption_token() { :; }; service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
if write_config 443 uuid dec enc encryption; then exit 81; fi
[[ "$ROLLBACK_DIR" = "$RUN/pending" && ! -e "$XRAY_CONFIG" ]]
''')
 def test_restart_requires_real_stable_process(self):
  self.run_case(['restart_xray'] + (['xray_main_pid'] if 'xray_main_pid()' in SRC else []),r'''
systemctl() { if [[ "$1" = show ]]; then printf '0\n'; else return 0; fi; }
if restart_xray; then exit 81; fi
''')
 def test_dropin_only_uninstall(self):
  self.run_case(['uninstall_xray'] + [n for n in ('xray_pids','stop_xray_processes','has_xray_residue') if n+'()' in SRC],r'''
mkdir -p "$RUN/system/xray.service.d"
printf OLD > "$RUN/system/xray.service.d/custom.conf"
read() { confirm=y; }
systemctl() { case "$1" in is-active|is-enabled) return 1;; *) return 0;; esac; }
pgrep() { return 1; }
run_official_installer() { exit 81; }
uninstall_xray
[[ ! -d "$RUN/system/xray.service.d" ]]
''')
 def test_fresh_rollback_removes_generated_dropins(self):
  self.run_case(['restore_install_snapshot','clear_install_snapshot'],r'''
INSTALL_ROLLBACK_DIR="$RUN/snapshot"; mkdir -p "$INSTALL_ROLLBACK_DIR" "$RUN/system/xray.service.d" "$RUN/system/xray@.service.d" "$RUN/geo"
printf NEW > "$RUN/system/xray.service.d/10.conf"
systemctl() { return 0; }
restore_install_snapshot
[[ ! -e "$RUN/system/xray.service.d" && ! -e "$RUN/system/xray@.service.d" ]]
''')
 def test_invalid_subscription_rejected(self):
  self.run_case(['show_subscription','validate_encryption_token','valid_appearance','valid_port','valid_uuid','uri_encode'],r'''
printf '%s' '{"inbounds":[{"port":443,"settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000000"}],"decryption":"old"}}]}' > "$XRAY_CONFIG"
printf INVALID > "$ENCRYPTION_INFO"
public_ip() { printf 192.0.2.1; }
if show_subscription; then exit 81; fi
[[ ! -e "$SUBSCRIPTION_INFO" ]]
''')
 def test_target_sync(self):
  self.run_case(['write_config'],r'''
validate_encryption_token() { :; }; validate_reality_key() { :; }; valid_sni() { :; }; valid_short_id() { :; }
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
printf '%s' '{"inbounds":[{"settings":{"clients":[{"id":"old"}]},"streamSettings":{"security":"reality","realitySettings":{"target":"old.example:443","dest":"old.example:443","serverNames":["old.example"]}}}]}' > "$XRAY_CONFIG"
write_config 443 uuid dec enc reality private public new.example 20220701 true
jq -e '.inbounds[0].streamSettings.realitySettings | (.target // .dest)=="new.example:443"' "$XRAY_CONFIG"
''')
 def test_port_query_failure(self):
  self.run_case(['port_in_use'],'''ss() { return 77; }; netstat() { return 77; }
if port_in_use 443; then exit 81; else [[ $? = 2 ]]; fi''')
 def test_ipv6(self):
  self.run_case(['valid_ipv6'],'''for ip in '1::2:' ':1::2'; do if valid_ipv6 "$ip"; then exit 81; fi; done
for ip in '::' '::1' '2001:db8::' '::ffff:192.0.2.1'; do valid_ipv6 "$ip" || exit 82; done''')
if __name__=='__main__':unittest.main(verbosity=2)
